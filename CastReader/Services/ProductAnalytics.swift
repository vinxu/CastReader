//
//  ProductAnalytics.swift
//  CastReader
//
//  First-party product analytics for the shared iOS/Android funnel contract.
//  The payload is dual-format: v2 fields are authoritative, while legacy
//  event/deviceId/timestamp/version keep already-deployed /api/events compatible.
//

import Foundation

enum AnalyticsEventName: String, Codable, CaseIterable, Sendable {
    case appSessionStart = "app_session_start"
    case onboardingStep = "onboarding_step"
    case libraryConnection = "library_connection"
    case contentInputStage = "content_input_stage"
    case contentIntent = "content_intent"
    case contentReady = "content_ready"
    case contentFailed = "content_failed"
    case youtubeShareReceived = "yt_share_received"
    case youtubeHomeView = "yt_home_view"
    case youtubeExtractDone = "yt_extract_done"
    case youtubeExtractFail = "yt_extract_fail"
    case youtubeCaptionLanguageOpen = "yt_caption_language_open"
    case youtubeCaptionLanguageSwitch = "yt_caption_language_switch"
    case readStart = "read_start"
    case readFirstAudio = "read_first_audio"
    case readMilestone = "read_milestone"
    case readEnd = "read_end"
    case explainStart = "explain_start"
    case explainFirstBlock = "explain_first_block"
    case explainMilestone = "explain_milestone"
    case explainEnd = "explain_end"
    case paywallShown = "paywall_shown"
    case homeProCardImpression = "home_pro_card_impression"
    case homeProCardYearlyPurchaseTap = "home_pro_card_yearly_purchase_tap"
    case homeProCardSecondaryTap = "home_pro_card_secondary_tap"
    case purchaseStart = "purchase_start"
    case purchaseResult = "purchase_result"
    case entitlementActivated = "entitlement_activated"
    case reviewPromptEligible = "review_prompt_eligible"
    case reviewRequestAttempted = "review_request_attempted"
    case reviewStoreLinkOpened = "review_store_link_opened"

    var legacyEvent: String {
        switch self {
        case .appSessionStart: return "session_start"
        case .onboardingStep: return "onboarding_step"
        case .libraryConnection: return "library_connection"
        case .contentInputStage: return "content_input_stage"
        case .contentIntent: return "feature_use"
        case .contentReady: return "reader_file_loaded"
        case .contentFailed: return "reader_file_error"
        case .youtubeShareReceived: return "yt_share_received"
        case .youtubeHomeView: return "yt_home_view"
        case .youtubeExtractDone: return "yt_extract_done"
        case .youtubeExtractFail: return "yt_extract_fail"
        case .youtubeCaptionLanguageOpen: return "yt_caption_language_open"
        case .youtubeCaptionLanguageSwitch: return "yt_caption_language_switch"
        case .readStart: return "reading_start"
        case .readFirstAudio: return "perf_metric"
        case .readMilestone: return "playback_progress"
        case .readEnd: return "reading_end"
        case .explainStart: return "quickread_pipeline_start"
        case .explainFirstBlock: return "quickread_player_open"
        case .explainMilestone: return "quickread_video_complete"
        case .explainEnd: return "quickread_pipeline_done"
        case .paywallShown: return "paywall_shown"
        case .homeProCardImpression: return "home_pro_card_impression"
        case .homeProCardYearlyPurchaseTap: return "home_pro_card_yearly_purchase_tap"
        case .homeProCardSecondaryTap: return "home_pro_card_secondary_tap"
        case .purchaseStart: return "checkout_started"
        case .purchaseResult: return "checkout_completed"
        case .entitlementActivated: return "pro_activated"
        case .reviewPromptEligible: return "rating_prompt_eligible"
        case .reviewRequestAttempted: return "rating_prompt"
        case .reviewStoreLinkOpened: return "rating_store_link_opened"
        }
    }
}

enum AnalyticsProductArea: String, Codable, Sendable {
    case app
    case reader
    case readAloud = "read_aloud"
    case explain
    case billing
}

enum AnalyticsResult: String, Codable, Sendable {
    case started
    case success
    case cancelled
    case blocked
    case failed
    case pending
}

enum AnalyticsLibrarySource: String, Codable, CaseIterable, Sendable {
    case kindle
    case weread
    case googleBooks = "google_books"
    case kobo
    case oreilly
}

enum AnalyticsLibraryConnectionStage: String, Codable, CaseIterable, Sendable {
    case entryTapped = "entry_tapped"
    case connectionPresented = "connection_presented"
    case loginStarted = "login_started"
    case loginSucceeded = "login_succeeded"
    case syncStarted = "sync_started"
    case syncCompleted = "sync_completed"
    case cancelled
    case failed
}

enum AnalyticsContentInputStage: String, Codable, CaseIterable, Sendable {
    case sourceOpened = "source_opened"
    case inputConfirmed = "input_confirmed"
    case processingStarted = "processing_started"
    case processingCompleted = "processing_completed"
    case cancelled
    case failed
}

enum AnalyticsContentSource: String, Codable, CaseIterable, Sendable {
    case camera
    case photoLibrary = "photo_library"
    case file
    case url
    case text
    case clipboard
    case shareSheet = "share_sheet"
    case system
    case history
    case kindle
    case weread
    case googleBooks = "google_books"
    case kobo
    case oreilly
    case googleDrive = "google_drive"
    case dropbox
    case oneDrive = "onedrive"
    case youtubeIOS = "youtube_ios"
    case unknown
}

enum AnalyticsContentFormat: String, Codable, CaseIterable, Sendable {
    case photo
    case pdf
    case epub
    case docx
    case text
    case web
    case kindle
    case weread
    case googleBooks = "google_books"
    case kobo
    case oreilly
    case youtube
    case unknown
}

struct AnalyticsProperties: Codable, Equatable, Sendable {
    var launchType: String?
    var step: String?
    var source: String?
    var bindSessionId: String?
    var stage: String?
    var contentSource: String?
    var contentFormat: String?
    var intendedMode: String?
    var lengthBucket: String?
    var paragraphCountBucket: String?
    var latencyMs: Int?
    var durationMs: Int?
    var result: String?
    var errorStage: String?
    var errorCode: String?
    var storefront: String?
    var language: String?
    var voiceId: String?
    var speed: Double?
    var resume: Bool?
    var milestoneSeconds: Int?
    var playbackSeconds: Int?
    var completionBucket: String?
    var endReason: String?
    var scenario: String?
    var milestone: String?
    var blocksStarted: Int?
    var blocksCompleted: Int?
    var trigger: String?
    var entitlementState: String?
    var hadMeaningfulReading: Bool?
    var store: String?
    var productId: String?
    var activationSource: String?
    var syncState: String?
    var bookCountBucket: String?
    var transactionEnvironment: String?
    var entry: String?
    var firstTime: Bool?
    var cueCount: Int?
    var paragraphCount: Int?
    var elapsedMs: Int?
    var reason: String?
    var trackCount: Int?
    var playableTrackCount: Int?
    var fromLanguage: String?
    var toLanguage: String?
    var kind: String?
    var cacheHit: Bool?
    var warmSession: Bool?

    init(
        launchType: String? = nil,
        step: String? = nil,
        source: String? = nil,
        bindSessionId: String? = nil,
        stage: String? = nil,
        contentSource: String? = nil,
        contentFormat: String? = nil,
        intendedMode: String? = nil,
        lengthBucket: String? = nil,
        paragraphCountBucket: String? = nil,
        latencyMs: Int? = nil,
        durationMs: Int? = nil,
        result: String? = nil,
        errorStage: String? = nil,
        errorCode: String? = nil,
        language: String? = nil,
        voiceId: String? = nil,
        speed: Double? = nil,
        resume: Bool? = nil,
        milestoneSeconds: Int? = nil,
        playbackSeconds: Int? = nil,
        completionBucket: String? = nil,
        endReason: String? = nil,
        scenario: String? = nil,
        milestone: String? = nil,
        blocksStarted: Int? = nil,
        blocksCompleted: Int? = nil,
        trigger: String? = nil,
        entitlementState: String? = nil,
        hadMeaningfulReading: Bool? = nil,
        store: String? = nil,
        productId: String? = nil,
        activationSource: String? = nil,
        syncState: String? = nil,
        bookCountBucket: String? = nil,
        transactionEnvironment: String? = nil,
        entry: String? = nil,
        firstTime: Bool? = nil,
        cueCount: Int? = nil,
        paragraphCount: Int? = nil,
        elapsedMs: Int? = nil,
        reason: String? = nil,
        trackCount: Int? = nil,
        playableTrackCount: Int? = nil,
        fromLanguage: String? = nil,
        toLanguage: String? = nil,
        kind: String? = nil,
        cacheHit: Bool? = nil,
        warmSession: Bool? = nil,
        storefront: String? = nil
    ) {
        self.launchType = launchType
        self.step = step
        self.source = source
        self.bindSessionId = bindSessionId
        self.stage = stage
        self.contentSource = contentSource
        self.contentFormat = contentFormat
        self.intendedMode = intendedMode
        self.lengthBucket = lengthBucket
        self.paragraphCountBucket = paragraphCountBucket
        self.latencyMs = latencyMs
        self.durationMs = durationMs
        self.result = result
        self.errorStage = errorStage
        self.errorCode = errorCode
        self.storefront = storefront
        self.language = language
        self.voiceId = voiceId
        self.speed = speed
        self.resume = resume
        self.milestoneSeconds = milestoneSeconds
        self.playbackSeconds = playbackSeconds
        self.completionBucket = completionBucket
        self.endReason = endReason
        self.scenario = scenario
        self.milestone = milestone
        self.blocksStarted = blocksStarted
        self.blocksCompleted = blocksCompleted
        self.trigger = trigger
        self.entitlementState = entitlementState
        self.hadMeaningfulReading = hadMeaningfulReading
        self.store = store
        self.productId = productId
        self.activationSource = activationSource
        self.syncState = syncState
        self.bookCountBucket = bookCountBucket
        self.transactionEnvironment = transactionEnvironment
        self.entry = entry
        self.firstTime = firstTime
        self.cueCount = cueCount
        self.paragraphCount = paragraphCount
        self.elapsedMs = elapsedMs
        self.reason = reason
        self.trackCount = trackCount
        self.playableTrackCount = playableTrackCount
        self.fromLanguage = fromLanguage
        self.toLanguage = toLanguage
        self.kind = kind
        self.cacheHit = cacheHit
        self.warmSession = warmSession
    }
}

struct AnalyticsLibraryConnectionSession: Equatable, Sendable {
    let bindSessionId: String
    let source: AnalyticsLibrarySource
    let entryPoint: String
    let startedAt: Date

    init(
        bindSessionId: String = UUID().uuidString,
        source: AnalyticsLibrarySource,
        entryPoint: String,
        startedAt: Date = Date()
    ) {
        self.bindSessionId = bindSessionId
        self.source = source
        self.entryPoint = entryPoint
        self.startedAt = startedAt
    }
}

/// Reusable, privacy-safe lifecycle recorder for every bound-library UI.
/// It deliberately owns no account, URL, title, or credential data.
final class AnalyticsLibraryConnectionRecorder: @unchecked Sendable {
    let session: AnalyticsLibraryConnectionSession

    private let lock = NSLock()
    private var entryTapAlreadyTracked: Bool
    private var terminalRecorded = false
    private var recordedKeys = Set<String>()

    init(
        session: AnalyticsLibraryConnectionSession,
        entryTapAlreadyTracked: Bool
    ) {
        self.session = session
        self.entryTapAlreadyTracked = entryTapAlreadyTracked
    }

    func presented() {
        lock.lock()
        let shouldRecordEntryTap = !entryTapAlreadyTracked
        entryTapAlreadyTracked = true
        lock.unlock()
        if shouldRecordEntryTap {
            record(
                .entryTapped,
                result: .started,
                occurredAt: session.startedAt
            )
        }
        record(.connectionPresented, result: .success, occurredAt: Date())
    }

    func record(
        _ stage: AnalyticsLibraryConnectionStage,
        result: AnalyticsResult,
        errorCode: String? = nil,
        bookCount: Int? = nil,
        occurredAt: Date = Date()
    ) {
        let key = "\(stage.rawValue):\(result.rawValue):\(errorCode ?? "-")"
        lock.lock()
        guard !terminalRecorded else {
            lock.unlock()
            return
        }
        let inserted = recordedKeys.insert(key).inserted
        if inserted,
           stage == .syncCompleted || stage == .failed || stage == .cancelled {
            terminalRecorded = true
        }
        lock.unlock()
        guard inserted else { return }
        let analyticsSession = session
        Task { @MainActor in
            ProductAnalytics.shared.trackLibraryConnection(
                analyticsSession,
                stage: stage,
                result: result,
                errorCode: errorCode,
                bookCount: bookCount,
                occurredAt: occurredAt
            )
        }
    }

    func close() {
        lock.lock()
        let shouldCancel = !terminalRecorded
        lock.unlock()
        if shouldCancel { record(.cancelled, result: .cancelled) }
    }
}

struct AnalyticsEventContext: Equatable, Sendable {
    var productArea: AnalyticsProductArea
    var surface: String
    var entryPoint: String?
    var contentSessionId: String?
    var readSessionId: String?
    var explainSessionId: String?
    var purchaseAttemptId: String?

    init(
        productArea: AnalyticsProductArea,
        surface: String,
        entryPoint: String?,
        contentSessionId: String? = nil,
        readSessionId: String? = nil,
        explainSessionId: String? = nil,
        purchaseAttemptId: String? = nil
    ) {
        self.productArea = productArea
        self.surface = surface
        self.entryPoint = entryPoint
        self.contentSessionId = contentSessionId
        self.readSessionId = readSessionId
        self.explainSessionId = explainSessionId
        self.purchaseAttemptId = purchaseAttemptId
    }
}

struct AnalyticsContentContext: Equatable, Sendable {
    let contentSessionId: String
    let source: AnalyticsContentSource
    let format: AnalyticsContentFormat
    let entryPoint: String
    let intendedMode: String
    let storefront: String?
    let startedAt: Date

    static func fallback(for document: ReadingDocument, entryPoint: String = "reader_open") -> AnalyticsContentContext {
        let storefront = document.sourceKind == .kindle
            ? KindleStorefront.entry(rawURL: document.sourceURL)?.id
            : nil
        return AnalyticsContentContext(
            contentSessionId: UUID().uuidString,
            source: AnalyticsContentSource(boundLibrary: document.sourceKind),
            format: AnalyticsContentFormat(document.sourceKind),
            entryPoint: entryPoint,
            intendedMode: "read",
            storefront: storefront,
            startedAt: Date()
        )
    }
}

extension AnalyticsContentSource {
    /// 绑定书库来源之外一律 unknown：
    /// 自带内容的来源由具体导入入口决定，不能从 sourceKind 反推。
    init(boundLibrary sourceKind: ReadingSourceKind) {
        switch sourceKind {
        case .kindle: self = .kindle
        case .weread: self = .weread
        case .googleBooks: self = .googleBooks
        case .kobo: self = .kobo
        case .oreilly: self = .oreilly
        case .youtube: self = .youtubeIOS
        default: self = .unknown
        }
    }
}

extension AnalyticsContentFormat {
    init(_ sourceKind: ReadingSourceKind) {
        switch sourceKind {
        case .photo: self = .photo
        case .kindle: self = .kindle
        case .weread: self = .weread
        case .googleBooks: self = .googleBooks
        case .kobo: self = .kobo
        case .oreilly: self = .oreilly
        case .text: self = .text
        case .web: self = .web
        case .docx: self = .docx
        case .pdf: self = .pdf
        case .epub: self = .epub
        case .youtube: self = .youtube
        }
    }
}

struct AnalyticsEventEnvelope: Codable, Equatable, Identifiable, Sendable {
    let eventId: String
    let eventName: AnalyticsEventName
    let eventVersion: Int
    let occurredAt: String
    let environment: String
    let clientPlatform: String
    let clientVariant: String
    let clientVersion: String
    let clientBuild: String?
    let anonymousId: String
    let backendUserId: String?
    let appSessionId: String
    let contentSessionId: String?
    let readSessionId: String?
    let explainSessionId: String?
    let purchaseAttemptId: String?
    let productArea: AnalyticsProductArea
    let surface: String
    let entryPoint: String?
    let properties: AnalyticsProperties

    // Backwards-compatible fields consumed by the already deployed collector.
    let event: String
    let deviceId: String
    let timestamp: String
    let version: String

    var id: String { eventId }
}

enum AnalyticsSchemaError: Error, Equatable, LocalizedError {
    case unknownEvent(String)
    case missingProperties([String])
    case unknownProperties([String])
    case forbiddenProperties([String])
    case invalidPropertyValue(property: String, value: String)

    var errorDescription: String? {
        switch self {
        case .unknownEvent(let name): return "unknown event: \(name)"
        case .missingProperties(let keys): return "missing properties: \(keys.joined(separator: ","))"
        case .unknownProperties(let keys): return "unknown properties: \(keys.joined(separator: ","))"
        case .forbiddenProperties(let keys): return "forbidden properties: \(keys.joined(separator: ","))"
        case .invalidPropertyValue(let property, let value):
            return "invalid \(property): \(value)"
        }
    }
}

enum AnalyticsSchema {
    private struct Definition {
        let required: Set<String>
        let optional: Set<String>
    }

    private static let definitions: [AnalyticsEventName: Definition] = [
        .appSessionStart: .init(required: ["launchType"], optional: []),
        .onboardingStep: .init(required: ["step", "result", "source"], optional: []),
        .libraryConnection: .init(
            required: ["bindSessionId", "source", "stage", "result"],
            optional: ["errorCode", "durationMs", "bookCountBucket"]
        ),
        .contentInputStage: .init(
            required: ["contentSource", "contentFormat", "stage", "result"],
            optional: ["intendedMode", "durationMs", "errorCode", "storefront"]
        ),
        .contentIntent: .init(required: ["contentSource", "contentFormat"], optional: ["intendedMode", "storefront"]),
        .contentReady: .init(required: ["contentSource", "contentFormat", "lengthBucket", "paragraphCountBucket"], optional: ["latencyMs", "storefront"]),
        .contentFailed: .init(required: ["contentSource", "contentFormat", "result", "errorStage", "errorCode"], optional: ["latencyMs", "storefront"]),
        .youtubeShareReceived: .init(required: ["entry"], optional: []),
        .youtubeHomeView: .init(required: ["firstTime"], optional: []),
        .youtubeExtractDone: .init(
            required: ["cueCount", "paragraphCount", "language", "elapsedMs"],
            optional: ["warmSession"]
        ),
        .youtubeExtractFail: .init(required: ["reason"], optional: []),
        .youtubeCaptionLanguageOpen: .init(
            required: ["trackCount"],
            optional: ["playableTrackCount"]
        ),
        .youtubeCaptionLanguageSwitch: .init(
            required: ["fromLanguage", "toLanguage", "kind"],
            optional: ["cacheHit", "elapsedMs"]
        ),
        .readStart: .init(required: ["contentSource", "contentFormat", "language", "voiceId", "speed", "resume"], optional: ["storefront"]),
        .readFirstAudio: .init(required: ["latencyMs", "language", "voiceId"], optional: ["storefront"]),
        .readMilestone: .init(required: ["milestoneSeconds", "playbackSeconds"], optional: ["completionBucket", "storefront"]),
        .readEnd: .init(required: ["result", "endReason", "playbackSeconds", "completionBucket"], optional: ["errorStage", "errorCode", "storefront"]),
        .explainStart: .init(required: ["contentSource", "contentFormat", "language", "scenario"], optional: ["storefront"]),
        .explainFirstBlock: .init(required: ["latencyMs", "scenario"], optional: ["storefront"]),
        .explainMilestone: .init(required: ["milestone", "blocksStarted", "blocksCompleted"], optional: ["storefront"]),
        .explainEnd: .init(required: ["result", "endReason", "blocksStarted", "blocksCompleted", "completionBucket"], optional: ["errorStage", "errorCode", "storefront"]),
        .paywallShown: .init(required: ["trigger", "entitlementState"], optional: ["hadMeaningfulReading"]),
        .homeProCardImpression: .init(required: [], optional: []),
        .homeProCardYearlyPurchaseTap: .init(required: [], optional: []),
        .homeProCardSecondaryTap: .init(required: [], optional: []),
        .purchaseStart: .init(
            required: ["store", "productId", "trigger"],
            optional: ["transactionEnvironment"]
        ),
        .purchaseResult: .init(
            required: ["store", "productId", "trigger", "result"],
            optional: ["errorCode", "transactionEnvironment"]
        ),
        .entitlementActivated: .init(
            required: ["store", "productId", "trigger", "activationSource"],
            optional: ["syncState", "transactionEnvironment"]
        ),
        .reviewPromptEligible: .init(required: ["trigger", "store"], optional: []),
        .reviewRequestAttempted: .init(required: ["trigger", "store", "result"], optional: ["errorCode"]),
        .reviewStoreLinkOpened: .init(required: ["trigger", "store"], optional: []),
    ]

    private static let forbidden = Set([
        "content", "text", "ocrText", "fileName", "title", "url", "urlPath",
        "referrer", "email", "imageData", "rawError", "responseBody",
    ])

    static func validate(_ name: AnalyticsEventName, properties: AnalyticsProperties) throws {
        guard let definition = definitions[name] else {
            throw AnalyticsSchemaError.unknownEvent(name.rawValue)
        }
        let keys = try encodedKeys(properties)
        let forbiddenKeys = keys.intersection(forbidden)
        if !forbiddenKeys.isEmpty {
            throw AnalyticsSchemaError.forbiddenProperties(forbiddenKeys.sorted())
        }
        let missing = definition.required.subtracting(keys)
        if !missing.isEmpty {
            throw AnalyticsSchemaError.missingProperties(missing.sorted())
        }
        let unknown = keys.subtracting(definition.required.union(definition.optional))
        if !unknown.isEmpty {
            throw AnalyticsSchemaError.unknownProperties(unknown.sorted())
        }
        try validateConstrainedValues(name, properties: properties)
    }

    static var eventNames: Set<String> { Set(AnalyticsEventName.allCases.map(\.rawValue)) }

    private static func encodedKeys(_ properties: AnalyticsProperties) throws -> Set<String> {
        let data = try JSONEncoder().encode(properties)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
    }

    private static func validateConstrainedValues(
        _ name: AnalyticsEventName,
        properties: AnalyticsProperties
    ) throws {
        if let storefront = properties.storefront,
           KindleStorefront.entry(id: storefront)?.id != storefront {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "storefront",
                value: storefront
            )
        }
        if properties.contentSource == AnalyticsContentSource.kindle.rawValue,
           properties.storefront == nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "storefront",
                value: "nil"
            )
        }
        if properties.contentSource != nil,
           properties.contentSource != AnalyticsContentSource.kindle.rawValue,
           properties.storefront != nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "storefront",
                value: properties.storefront ?? "nil"
            )
        }

        if name == .libraryConnection {
            try validateLibraryConnection(properties)
            return
        }
        if name == .contentInputStage {
            try validateContentInputStage(properties)
            return
        }
        if name == .youtubeShareReceived
            || name == .youtubeHomeView
            || name == .youtubeExtractDone
            || name == .youtubeExtractFail
            || name == .youtubeCaptionLanguageOpen
            || name == .youtubeCaptionLanguageSwitch {
            try validateYouTubeEvent(name, properties: properties)
            return
        }
        if let transactionEnvironment = properties.transactionEnvironment,
           !["production", "sandbox", "xcode", "unknown"].contains(transactionEnvironment) {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "transactionEnvironment",
                value: transactionEnvironment
            )
        }
        guard name == .reviewPromptEligible
                || name == .reviewRequestAttempted
                || name == .reviewStoreLinkOpened else {
            return
        }
        if properties.store != "app_store" {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "store",
                value: properties.store ?? "nil"
            )
        }

        let allowedTriggers: Set<String> = name == .reviewStoreLinkOpened
            ? [AppReviewTrigger.settings.rawValue]
            : [
                AppReviewTrigger.firstReadCompleted.rawValue,
                AppReviewTrigger.libraryConnected.rawValue,
                AppReviewTrigger.thirdFiveMinuteRead.rawValue,
            ]
        if let trigger = properties.trigger,
           !allowedTriggers.contains(trigger) {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "trigger",
                value: trigger
            )
        } else if properties.trigger == nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "trigger",
                value: "nil"
            )
        }

        if name == .reviewRequestAttempted,
           properties.result != AnalyticsResult.success.rawValue,
           properties.result != AnalyticsResult.failed.rawValue {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "result",
                value: properties.result ?? "nil"
            )
        }
    }

    private static func validateLibraryConnection(_ properties: AnalyticsProperties) throws {
        guard let bindSessionId = properties.bindSessionId,
              UUID(uuidString: bindSessionId) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "bindSessionId",
                value: properties.bindSessionId ?? "nil"
            )
        }
        guard let source = properties.source,
              AnalyticsLibrarySource(rawValue: source) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "source",
                value: properties.source ?? "nil"
            )
        }
        guard let stageValue = properties.stage,
              let stage = AnalyticsLibraryConnectionStage(rawValue: stageValue) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "stage",
                value: properties.stage ?? "nil"
            )
        }
        let expectedResult: AnalyticsResult = switch stage {
        case .entryTapped, .loginStarted, .syncStarted: .started
        case .connectionPresented, .loginSucceeded, .syncCompleted: .success
        case .cancelled: .cancelled
        case .failed: .failed
        }
        guard properties.result == expectedResult.rawValue else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "result",
                value: properties.result ?? "nil"
            )
        }
        if let durationMs = properties.durationMs, durationMs < 0 {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "durationMs",
                value: String(durationMs)
            )
        }
        if let bookCountBucket = properties.bookCountBucket,
           !["none", "1", "2_5", "6_20", "21_50", "51_plus", "unknown"].contains(bookCountBucket) {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "bookCountBucket",
                value: bookCountBucket
            )
        }
        if stage == .failed, properties.errorCode == nil {
            throw AnalyticsSchemaError.invalidPropertyValue(property: "errorCode", value: "nil")
        }
        if stage != .failed, properties.errorCode != nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "errorCode",
                value: properties.errorCode ?? "nil"
            )
        }
    }

    private static func validateYouTubeEvent(
        _ name: AnalyticsEventName,
        properties: AnalyticsProperties
    ) throws {
        if name == .youtubeShareReceived {
            guard let entry = properties.entry,
                  ["share", "clipboard", "scheme", "paste", "sample"].contains(entry) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "entry",
                    value: properties.entry ?? "nil"
                )
            }
        }
        if name == .youtubeExtractDone {
            if let cueCount = properties.cueCount, cueCount <= 0 {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "cueCount",
                    value: String(cueCount)
                )
            }
            if let paragraphCount = properties.paragraphCount, paragraphCount <= 0 {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "paragraphCount",
                    value: String(paragraphCount)
                )
            }
            if let elapsedMs = properties.elapsedMs, elapsedMs < 0 {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "elapsedMs",
                    value: String(elapsedMs)
                )
            }
            if properties.language?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "language",
                    value: properties.language ?? "nil"
                )
            }
        }
        if name == .youtubeExtractFail {
            guard let reason = properties.reason,
                  [
                    "no_captions",
                    "live",
                    "restricted",
                    "unavailable",
                    "caption_access",
                    "track_unavailable",
                    "timeout",
                    "unsupported_language",
                  ].contains(reason) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "reason",
                    value: properties.reason ?? "nil"
                )
            }
        }
        if name == .youtubeCaptionLanguageOpen {
            guard let trackCount = properties.trackCount, trackCount > 0 else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "trackCount",
                    value: properties.trackCount.map(String.init) ?? "nil"
                )
            }
            if let playable = properties.playableTrackCount,
               playable < 0 || playable > trackCount {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "playableTrackCount",
                    value: String(playable)
                )
            }
        }
        if name == .youtubeCaptionLanguageSwitch {
            for (property, value) in [
                ("fromLanguage", properties.fromLanguage),
                ("toLanguage", properties.toLanguage),
            ] {
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AnalyticsSchemaError.invalidPropertyValue(
                        property: property,
                        value: value ?? "nil"
                    )
                }
            }
            guard let kind = properties.kind, ["asr", "manual"].contains(kind) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "kind",
                    value: properties.kind ?? "nil"
                )
            }
        }
    }

    private static func validateContentInputStage(_ properties: AnalyticsProperties) throws {
        guard let source = properties.contentSource,
              AnalyticsContentSource(rawValue: source) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "contentSource",
                value: properties.contentSource ?? "nil"
            )
        }
        guard let format = properties.contentFormat,
              AnalyticsContentFormat(rawValue: format) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "contentFormat",
                value: properties.contentFormat ?? "nil"
            )
        }
        guard let stageValue = properties.stage,
              let stage = AnalyticsContentInputStage(rawValue: stageValue) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "stage",
                value: properties.stage ?? "nil"
            )
        }
        let expectedResult: AnalyticsResult = switch stage {
        case .sourceOpened, .processingStarted: .started
        case .inputConfirmed, .processingCompleted: .success
        case .cancelled: .cancelled
        case .failed: .failed
        }
        guard properties.result == expectedResult.rawValue else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "result",
                value: properties.result ?? "nil"
            )
        }
        if stage == .failed, properties.errorCode == nil {
            throw AnalyticsSchemaError.invalidPropertyValue(property: "errorCode", value: "nil")
        }
        if stage != .failed, properties.errorCode != nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "errorCode",
                value: properties.errorCode ?? "nil"
            )
        }
    }
}

struct AnalyticsClientInfo: Equatable, Sendable {
    let environment: String
    let platform: String
    let variant: String
    let version: String
    let build: String?
    let anonymousId: String
}

enum AnalyticsEnvelopeFactory {
    static func make(
        name: AnalyticsEventName,
        context: AnalyticsEventContext,
        properties: AnalyticsProperties,
        client: AnalyticsClientInfo,
        appSessionId: String,
        backendUserId: String?,
        eventId: String = UUID().uuidString,
        occurredAt: Date = Date()
    ) throws -> AnalyticsEventEnvelope {
        try AnalyticsSchema.validate(name, properties: properties)
        let timestamp = analyticsISO8601.string(from: occurredAt)
        let legacyEvent: String
        if name == .purchaseResult {
            switch properties.result {
            case AnalyticsResult.cancelled.rawValue: legacyEvent = "checkout_return_cancel"
            case AnalyticsResult.success.rawValue: legacyEvent = "checkout_completed"
            default: legacyEvent = "checkout_error"
            }
        } else {
            legacyEvent = name.legacyEvent
        }
        return AnalyticsEventEnvelope(
            eventId: eventId,
            eventName: name,
            eventVersion: 2,
            occurredAt: timestamp,
            environment: client.environment,
            clientPlatform: client.platform,
            clientVariant: client.variant,
            clientVersion: client.version,
            clientBuild: client.build,
            anonymousId: client.anonymousId,
            backendUserId: backendUserId,
            appSessionId: appSessionId,
            contentSessionId: context.contentSessionId,
            readSessionId: context.readSessionId,
            explainSessionId: context.explainSessionId,
            purchaseAttemptId: context.purchaseAttemptId,
            productArea: context.productArea,
            surface: context.surface,
            entryPoint: context.entryPoint,
            properties: properties,
            event: legacyEvent,
            deviceId: client.anonymousId,
            timestamp: timestamp,
            version: client.version
        )
    }
}

private let analyticsISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

protocol AnalyticsQueueStore: Sendable {
    func load() -> [AnalyticsEventEnvelope]
    func save(_ events: [AnalyticsEventEnvelope])
}

struct UserDefaultsAnalyticsQueueStore: AnalyticsQueueStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "product_analytics_queue_v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [AnalyticsEventEnvelope] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AnalyticsEventEnvelope].self, from: data)) ?? []
    }

    func save(_ events: [AnalyticsEventEnvelope]) {
        if events.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: key)
        }
    }
}

struct AnalyticsTransportResult: Equatable, Sendable {
    let acceptedEventIds: Set<String>
    let rejectedEventIds: Set<String>
    let rejectionReasons: [String: String]

    init(
        acceptedEventIds: Set<String>,
        rejectedEventIds: Set<String>,
        rejectionReasons: [String: String] = [:]
    ) {
        self.acceptedEventIds = acceptedEventIds
        self.rejectedEventIds = rejectedEventIds
        self.rejectionReasons = rejectionReasons
    }
}

struct AnalyticsDeadLetterRecord: Codable, Equatable, Sendable {
    let eventId: String
    let eventName: String
    let reason: String
    let clientVersion: String
    let rejectedAt: String
}

protocol AnalyticsDeadLetterStore: Sendable {
    func load() -> [AnalyticsDeadLetterRecord]
    func save(_ records: [AnalyticsDeadLetterRecord])
}

struct UserDefaultsAnalyticsDeadLetterStore: AnalyticsDeadLetterStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "product_analytics_dead_letters_v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [AnalyticsDeadLetterRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AnalyticsDeadLetterRecord].self, from: data)) ?? []
    }

    func save(_ records: [AnalyticsDeadLetterRecord]) {
        if records.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}

protocol AnalyticsTransport: Sendable {
    func send(_ events: [AnalyticsEventEnvelope]) async throws -> AnalyticsTransportResult
}

enum AnalyticsTransportError: Error, LocalizedError {
    case invalidResponse
    case http(Int)
    case server(String)
    case degraded(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "invalid analytics response"
        case .http(let code): return "analytics HTTP \(code)"
        case .server(let message): return message
        case .degraded(let reason): return "analytics degraded: \(reason)"
        }
    }
}

struct URLSessionAnalyticsTransport: AnalyticsTransport {
    private struct RequestBody: Encodable { let events: [AnalyticsEventEnvelope] }
    private struct ResponseBody: Decodable {
        struct DataBody: Decodable {
            struct Rejected: Decodable {
                let eventId: String?
                let reason: String?
            }
            let acceptedEventIds: [String]?
            let rejected: [Rejected]?
            let inserted: Int?
            let queued: Int?
            let dropped: Int?
            let degraded: Bool?
            let reason: String?
        }
        let code: Int
        let message: String
        let data: DataBody?
    }

    let endpoint: URL
    var session: URLSession = .shared

    func send(_ events: [AnalyticsEventEnvelope]) async throws -> AnalyticsTransportResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(events: events))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnalyticsTransportError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AnalyticsTransportError.http(http.statusCode) }
        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard body.code == 0 else { throw AnalyticsTransportError.server(body.message) }
        if body.data?.degraded == true, (body.data?.dropped ?? 0) > 0 {
            throw AnalyticsTransportError.degraded(body.data?.reason ?? "dropped")
        }
        if let accepted = body.data?.acceptedEventIds {
            let rejectedRows = body.data?.rejected ?? []
            let rejected = Set(rejectedRows.compactMap(\.eventId))
            let reasons = rejectedRows.reduce(into: [String: String]()) { result, row in
                guard let eventId = row.eventId else { return }
                result[eventId] = row.reason ?? "server_rejected"
            }
            return AnalyticsTransportResult(
                acceptedEventIds: Set(accepted),
                rejectedEventIds: rejected,
                rejectionReasons: reasons
            )
        }
        // Legacy collector returns aggregate inserted/queued counts only. The
        // contract's legacy mappings are allowlisted, so a non-degraded success
        // acknowledges the whole batch.
        let acceptedCount = (body.data?.inserted ?? 0) + (body.data?.queued ?? 0)
        guard acceptedCount >= events.count else {
            throw AnalyticsTransportError.invalidResponse
        }
        return AnalyticsTransportResult(
            acceptedEventIds: Set(events.map(\.eventId)),
            rejectedEventIds: []
        )
    }
}

actor AnalyticsPipeline {
    private let store: AnalyticsQueueStore
    private let deadLetterStore: AnalyticsDeadLetterStore
    private let transport: AnalyticsTransport
    private let batchSize: Int
    private let maxQueueSize: Int
    private let maxDeadLetterSize: Int
    private var queue: [AnalyticsEventEnvelope]
    private var deadLetters: [AnalyticsDeadLetterRecord]
    private var isFlushing = false

    init(
        store: AnalyticsQueueStore,
        transport: AnalyticsTransport,
        batchSize: Int = 20,
        maxQueueSize: Int = 500,
        deadLetterStore: AnalyticsDeadLetterStore = UserDefaultsAnalyticsDeadLetterStore(),
        maxDeadLetterSize: Int = 50
    ) {
        self.store = store
        self.deadLetterStore = deadLetterStore
        self.transport = transport
        self.batchSize = batchSize
        self.maxQueueSize = maxQueueSize
        self.maxDeadLetterSize = maxDeadLetterSize
        self.queue = Array(store.load().suffix(maxQueueSize))
        self.deadLetters = Array(deadLetterStore.load().suffix(maxDeadLetterSize))
    }

    func enqueue(_ event: AnalyticsEventEnvelope) async {
        if !queue.contains(where: { $0.eventId == event.eventId }) {
            queue.append(event)
            if queue.count > maxQueueSize { queue.removeFirst(queue.count - maxQueueSize) }
            store.save(queue)
        }
        if queue.count >= batchSize { await flush() }
    }

    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !queue.isEmpty {
            let batch = Array(queue.prefix(batchSize))
            do {
                let result = try await transport.send(batch)
                let resolved = result.acceptedEventIds.union(result.rejectedEventIds)
                guard !resolved.isEmpty else { return }
                if !result.rejectedEventIds.isEmpty {
                    retainRejectedEvents(
                        batch,
                        rejectedEventIds: result.rejectedEventIds,
                        reasons: result.rejectionReasons
                    )
                }
                queue.removeAll { resolved.contains($0.eventId) }
                store.save(queue)
            } catch {
                #if DEBUG
                print("⚠️ [Analytics] flush retained \(queue.count) events: \(error.localizedDescription)")
                #endif
                return
            }
        }
    }

    func queuedEvents() -> [AnalyticsEventEnvelope] { queue }
    func rejectedEvents() -> [AnalyticsDeadLetterRecord] { deadLetters }

    private func retainRejectedEvents(
        _ batch: [AnalyticsEventEnvelope],
        rejectedEventIds: Set<String>,
        reasons: [String: String]
    ) {
        let rejectedAt = analyticsISO8601.string(from: Date())
        for event in batch where rejectedEventIds.contains(event.eventId) {
            deadLetters.removeAll { $0.eventId == event.eventId }
            deadLetters.append(
                AnalyticsDeadLetterRecord(
                    eventId: event.eventId,
                    eventName: event.eventName.rawValue,
                    reason: reasons[event.eventId] ?? "server_rejected",
                    clientVersion: event.clientVersion,
                    rejectedAt: rejectedAt
                )
            )
        }
        if deadLetters.count > maxDeadLetterSize {
            deadLetters.removeFirst(deadLetters.count - maxDeadLetterSize)
        }
        deadLetterStore.save(deadLetters)
#if DEBUG
        let reasonCounts = Dictionary(grouping: deadLetters, by: \.reason).mapValues(\.count)
        print("[Analytics] retained rejected-event summary: \(reasonCounts)")
#endif
    }
}

@MainActor
final class ProductAnalytics {
    static let shared = ProductAnalytics()

    private static let anonymousIdKey = "product_analytics_anonymous_id_v1"
    private let pipeline: AnalyticsPipeline
    private let client: AnalyticsClientInfo
    private(set) var appSessionId = UUID().uuidString
    private var appSessionStarted = false
    private var backgroundAt: Date?
    private var meaningfulReadReached = false
    private var scheduledFlushTask: Task<Void, Never>?

    private init() {
        let endpoint = URL(string: "https://castreader.ai/api/events")!
        let pipeline = AnalyticsPipeline(
            store: UserDefaultsAnalyticsQueueStore(),
            transport: URLSessionAnalyticsTransport(endpoint: endpoint)
        )
        self.pipeline = pipeline
        self.client = AnalyticsClientInfo(
            environment: Self.environment,
            platform: "ios",
            variant: Self.clientVariant,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            anonymousId: Self.analyticsAnonymousId()
        )
    }

    func startAppSession(launchType: String = "cold") {
        guard !appSessionStarted else { return }
        appSessionStarted = true
        track(
            .appSessionStart,
            context: .init(productArea: .app, surface: "app", entryPoint: nil),
            properties: .init(launchType: launchType)
        )
    }

    func didEnterBackground(at date: Date = Date()) {
        backgroundAt = date
        scheduledFlushTask?.cancel()
        Task { await pipeline.flush() }
    }

    func didBecomeActive(at date: Date = Date()) {
        if let backgroundAt, date.timeIntervalSince(backgroundAt) >= 30 * 60 {
            appSessionId = UUID().uuidString
            appSessionStarted = false
            startAppSession(launchType: "foreground_after_30m")
        } else {
            startAppSession()
        }
        self.backgroundAt = nil
        Task { await pipeline.flush() }
    }

    func beginContentIntent(
        source: AnalyticsContentSource,
        format: AnalyticsContentFormat,
        entryPoint: String,
        intendedMode: String,
        storefront: String? = nil
    ) -> AnalyticsContentContext {
        let context = AnalyticsContentContext(
            contentSessionId: UUID().uuidString,
            source: source,
            format: format,
            entryPoint: entryPoint,
            intendedMode: intendedMode,
            storefront: storefront,
            startedAt: Date()
        )
        confirmContentIntent(context)
        return context
    }

    /// Confirms that the user supplied real input. File pickers initially use
    /// `.unknown`; once a URL is returned we refine the format without
    /// changing the correlation id or start time.
    @discardableResult
    func confirmContentIntent(
        _ context: AnalyticsContentContext,
        format: AnalyticsContentFormat? = nil
    ) -> AnalyticsContentContext {
        let context = AnalyticsContentContext(
            contentSessionId: context.contentSessionId,
            source: context.source,
            format: format ?? context.format,
            entryPoint: context.entryPoint,
            intendedMode: context.intendedMode,
            storefront: context.storefront,
            startedAt: context.startedAt
        )
        let confirmedAt = Date()
        trackContentInputStage(
            .inputConfirmed,
            result: .success,
            content: context,
            occurredAt: confirmedAt
        )
        trackContentInputStage(
            .processingStarted,
            result: .started,
            content: context,
            occurredAt: confirmedAt.addingTimeInterval(0.001)
        )
        track(
            .contentIntent,
            context: .init(
                productArea: .reader,
                surface: "content_import",
                entryPoint: context.entryPoint,
                contentSessionId: context.contentSessionId
            ),
            properties: .init(
                contentSource: context.source.rawValue,
                contentFormat: context.format.rawValue,
                intendedMode: context.intendedMode,
                storefront: context.storefront
            )
        )
        return context
    }

    func contentReady(_ content: AnalyticsContentContext, document: ReadingDocument) {
        let completedAt = Date()
        trackContentInputStage(
            .processingCompleted,
            result: .success,
            content: content,
            occurredAt: completedAt
        )
        track(
            .contentReady,
            context: .init(
                productArea: .reader,
                surface: "reader",
                entryPoint: content.entryPoint,
                contentSessionId: content.contentSessionId
            ),
            properties: .init(
                contentSource: content.source.rawValue,
                contentFormat: AnalyticsContentFormat(document.sourceKind).rawValue,
                lengthBucket: Self.lengthBucket(document.fullText.count),
                paragraphCountBucket: Self.paragraphBucket(document.readableParagraphs.count),
                latencyMs: max(0, Int(completedAt.timeIntervalSince(content.startedAt) * 1000)),
                storefront: content.storefront
            )
        )
    }

    /// Some legacy formats are accepted for asynchronous library processing
    /// and do not open a reader in the same UI flow. They still need a terminal
    /// input-stage event so the import funnel is not left in `processing_started`.
    func contentInputCompleted(_ content: AnalyticsContentContext) {
        trackContentInputStage(
            .processingCompleted,
            result: .success,
            content: content
        )
    }

    func contentFailed(
        _ content: AnalyticsContentContext,
        stage: String,
        code: String
    ) {
        let failedAt = Date()
        trackContentInputStage(
            .failed,
            result: .failed,
            content: content,
            errorCode: code,
            occurredAt: failedAt
        )
        track(
            .contentFailed,
            context: .init(
                productArea: .reader,
                surface: "content_import",
                entryPoint: content.entryPoint,
                contentSessionId: content.contentSessionId
            ),
            properties: .init(
                contentSource: content.source.rawValue,
                contentFormat: content.format.rawValue,
                latencyMs: max(0, Int(failedAt.timeIntervalSince(content.startedAt) * 1000)),
                result: AnalyticsResult.failed.rawValue,
                errorStage: stage,
                errorCode: code,
                storefront: content.storefront
            )
        )
    }

    @discardableResult
    func beginLibraryConnection(
        source: AnalyticsLibrarySource,
        entryPoint: String,
        recordEntryTap: Bool = true
    ) -> AnalyticsLibraryConnectionSession {
        let session = AnalyticsLibraryConnectionSession(
            source: source,
            entryPoint: entryPoint
        )
        if recordEntryTap {
            trackLibraryConnection(session, stage: .entryTapped, result: .started)
        }
        return session
    }

    func trackLibraryConnection(
        _ session: AnalyticsLibraryConnectionSession,
        stage: AnalyticsLibraryConnectionStage,
        result: AnalyticsResult,
        errorCode: String? = nil,
        bookCount: Int? = nil,
        occurredAt: Date = Date()
    ) {
        track(
            .libraryConnection,
            context: .init(
                productArea: .reader,
                surface: "library_connection",
                entryPoint: session.entryPoint
            ),
            properties: .init(
                source: session.source.rawValue,
                bindSessionId: session.bindSessionId,
                stage: stage.rawValue,
                durationMs: max(0, Int(occurredAt.timeIntervalSince(session.startedAt) * 1000)),
                result: result.rawValue,
                errorCode: errorCode,
                bookCountBucket: bookCount.map(Self.bookCountBucket)
            ),
            occurredAt: occurredAt
        )
    }

    func trackContentSourceOpened(
        source: AnalyticsContentSource,
        format: AnalyticsContentFormat,
        entryPoint: String,
        intendedMode: String
    ) -> AnalyticsContentContext {
        let context = AnalyticsContentContext(
            contentSessionId: UUID().uuidString,
            source: source,
            format: format,
            entryPoint: entryPoint,
            intendedMode: intendedMode,
            storefront: nil,
            startedAt: Date()
        )
        trackContentInputStage(.sourceOpened, result: .started, content: context)
        return context
    }

    func trackContentInputCancelled(_ content: AnalyticsContentContext) {
        trackContentInputStage(.cancelled, result: .cancelled, content: content)
    }

    private func trackContentInputStage(
        _ stage: AnalyticsContentInputStage,
        result: AnalyticsResult,
        content: AnalyticsContentContext,
        errorCode: String? = nil,
        occurredAt: Date = Date()
    ) {
        track(
            .contentInputStage,
            context: .init(
                productArea: .reader,
                surface: "content_import",
                entryPoint: content.entryPoint,
                contentSessionId: content.contentSessionId
            ),
            properties: .init(
                stage: stage.rawValue,
                contentSource: content.source.rawValue,
                contentFormat: content.format.rawValue,
                intendedMode: content.intendedMode,
                durationMs: max(0, Int(occurredAt.timeIntervalSince(content.startedAt) * 1000)),
                result: result.rawValue,
                errorCode: errorCode,
                storefront: content.storefront
            ),
            occurredAt: occurredAt
        )
    }

    @discardableResult
    func track(
        _ name: AnalyticsEventName,
        context: AnalyticsEventContext,
        properties: AnalyticsProperties,
        eventId: String = UUID().uuidString,
        occurredAt: Date = Date()
    ) -> String? {
        startAppSession()
        do {
            let event = try AnalyticsEnvelopeFactory.make(
                name: name,
                context: context,
                properties: properties,
                client: client,
                appSessionId: appSessionId,
                backendUserId: AuthService.shared.proUserId,
                eventId: eventId,
                occurredAt: occurredAt
            )
            Task { await pipeline.enqueue(event) }
            scheduleFlush()
            return eventId
        } catch {
            // Analytics is strictly fail-open in every configuration. Contract
            // mistakes are visible in debug logs but can never interrupt a
            // reader, explanation, import, paywall, or StoreKit flow.
#if DEBUG
            print("[Analytics] dropped invalid event \(name.rawValue): \(error.localizedDescription)")
#endif
            return nil
        }
    }

    func noteMeaningfulReadReached() { meaningfulReadReached = true }
    var hadMeaningfulReading: Bool { meaningfulReadReached }
    func flush() async { await pipeline.flush() }

    private func scheduleFlush() {
        scheduledFlushTask?.cancel()
        scheduledFlushTask = Task { [pipeline] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await pipeline.flush()
        }
    }

    nonisolated static func completionBucket(completed: Int, total: Int) -> String {
        guard total > 0 else { return "unknown" }
        let ratio = Double(completed) / Double(total)
        switch ratio {
        case ..<0.001: return "none"
        case ..<0.25: return "lt_25"
        case ..<0.50: return "25_49"
        case ..<0.80: return "50_79"
        case ..<1.0: return "80_99"
        default: return "complete"
        }
    }

    nonisolated static func isMeaningfulExplainBlockProgress(_ progress: Double) -> Bool {
        progress >= 0.8
    }

    private static var environment: String {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return "test"
        }
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    static var clientVariant: String {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return clientVariant(
            isDebug: debug,
            isSimulator: simulator,
            receiptLastPathComponent: Bundle.main.appStoreReceiptURL?.lastPathComponent,
            hasEmbeddedProvisioningProfile:
                Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        )
    }

    nonisolated static func clientVariant(
        isDebug: Bool,
        isSimulator: Bool,
        receiptLastPathComponent: String?,
        hasEmbeddedProvisioningProfile: Bool
    ) -> String {
        if isSimulator { return "simulator" }
        if isDebug { return "internal_debug" }
        if receiptLastPathComponent == "sandboxReceipt" { return "testflight" }
        if hasEmbeddedProvisioningProfile { return "internal" }
        return "app_store"
    }

    private static func analyticsAnonymousId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: anonymousIdKey), UUID(uuidString: existing) != nil {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: anonymousIdKey)
        return id
    }

    private static func lengthBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "empty"
        case 1..<500: return "1_499"
        case 500..<2_000: return "500_1999"
        case 2_000..<10_000: return "2000_9999"
        case 10_000..<50_000: return "10000_49999"
        default: return "50000_plus"
        }
    }

    private static func paragraphBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case 1...5: return "1_5"
        case 6...20: return "6_20"
        case 21...100: return "21_100"
        default: return "101_plus"
        }
    }

    private static func bookCountBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "none"
        case 1: return "1"
        case 2...5: return "2_5"
        case 6...20: return "6_20"
        case 21...50: return "21_50"
        default: return "51_plus"
        }
    }
}
