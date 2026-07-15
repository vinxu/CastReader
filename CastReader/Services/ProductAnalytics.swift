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
    case contentIntent = "content_intent"
    case contentReady = "content_ready"
    case contentFailed = "content_failed"
    case readStart = "read_start"
    case readFirstAudio = "read_first_audio"
    case readMilestone = "read_milestone"
    case readEnd = "read_end"
    case explainStart = "explain_start"
    case explainFirstBlock = "explain_first_block"
    case explainMilestone = "explain_milestone"
    case explainEnd = "explain_end"
    case paywallShown = "paywall_shown"
    case purchaseStart = "purchase_start"
    case purchaseResult = "purchase_result"

    var legacyEvent: String {
        switch self {
        case .appSessionStart: return "session_start"
        case .contentIntent: return "feature_use"
        case .contentReady: return "reader_file_loaded"
        case .contentFailed: return "reader_file_error"
        case .readStart: return "reading_start"
        case .readFirstAudio: return "perf_metric"
        case .readMilestone: return "playback_progress"
        case .readEnd: return "reading_end"
        case .explainStart: return "quickread_pipeline_start"
        case .explainFirstBlock: return "quickread_player_open"
        case .explainMilestone: return "quickread_video_complete"
        case .explainEnd: return "quickread_pipeline_done"
        case .paywallShown: return "paywall_shown"
        case .purchaseStart: return "checkout_started"
        case .purchaseResult: return "checkout_completed"
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
    case success
    case cancelled
    case blocked
    case failed
    case pending
}

enum AnalyticsContentSource: String, Codable, Sendable {
    case camera
    case photoLibrary = "photo_library"
    case file
    case url
    case text
    case clipboard
    case history
    case kindle
    case unknown
}

enum AnalyticsContentFormat: String, Codable, Sendable {
    case photo
    case pdf
    case epub
    case docx
    case text
    case web
    case kindle
    case unknown
}

struct AnalyticsProperties: Codable, Equatable, Sendable {
    var launchType: String?
    var contentSource: String?
    var contentFormat: String?
    var intendedMode: String?
    var lengthBucket: String?
    var paragraphCountBucket: String?
    var latencyMs: Int?
    var result: String?
    var errorStage: String?
    var errorCode: String?
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

    init(
        launchType: String? = nil,
        contentSource: String? = nil,
        contentFormat: String? = nil,
        intendedMode: String? = nil,
        lengthBucket: String? = nil,
        paragraphCountBucket: String? = nil,
        latencyMs: Int? = nil,
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
        productId: String? = nil
    ) {
        self.launchType = launchType
        self.contentSource = contentSource
        self.contentFormat = contentFormat
        self.intendedMode = intendedMode
        self.lengthBucket = lengthBucket
        self.paragraphCountBucket = paragraphCountBucket
        self.latencyMs = latencyMs
        self.result = result
        self.errorStage = errorStage
        self.errorCode = errorCode
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
    let startedAt: Date

    static func fallback(for document: ReadingDocument, entryPoint: String = "reader_open") -> AnalyticsContentContext {
        AnalyticsContentContext(
            contentSessionId: UUID().uuidString,
            source: document.sourceKind == .kindle ? .kindle : .unknown,
            format: AnalyticsContentFormat(document.sourceKind),
            entryPoint: entryPoint,
            intendedMode: "read",
            startedAt: Date()
        )
    }
}

extension AnalyticsContentFormat {
    init(_ sourceKind: ReadingSourceKind) {
        switch sourceKind {
        case .photo: self = .photo
        case .kindle: self = .kindle
        case .text: self = .text
        case .web: self = .web
        case .docx: self = .docx
        case .pdf: self = .pdf
        case .epub: self = .epub
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

    var errorDescription: String? {
        switch self {
        case .unknownEvent(let name): return "unknown event: \(name)"
        case .missingProperties(let keys): return "missing properties: \(keys.joined(separator: ","))"
        case .unknownProperties(let keys): return "unknown properties: \(keys.joined(separator: ","))"
        case .forbiddenProperties(let keys): return "forbidden properties: \(keys.joined(separator: ","))"
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
        .contentIntent: .init(required: ["contentSource", "contentFormat"], optional: ["intendedMode"]),
        .contentReady: .init(required: ["contentSource", "contentFormat", "lengthBucket", "paragraphCountBucket"], optional: ["latencyMs"]),
        .contentFailed: .init(required: ["contentSource", "contentFormat", "result", "errorStage", "errorCode"], optional: ["latencyMs"]),
        .readStart: .init(required: ["contentSource", "contentFormat", "language", "voiceId", "speed", "resume"], optional: []),
        .readFirstAudio: .init(required: ["latencyMs", "language", "voiceId"], optional: []),
        .readMilestone: .init(required: ["milestoneSeconds", "playbackSeconds"], optional: ["completionBucket"]),
        .readEnd: .init(required: ["result", "endReason", "playbackSeconds", "completionBucket"], optional: ["errorStage", "errorCode"]),
        .explainStart: .init(required: ["contentSource", "contentFormat", "language", "scenario"], optional: []),
        .explainFirstBlock: .init(required: ["latencyMs", "scenario"], optional: []),
        .explainMilestone: .init(required: ["milestone", "blocksStarted", "blocksCompleted"], optional: []),
        .explainEnd: .init(required: ["result", "endReason", "blocksStarted", "blocksCompleted", "completionBucket"], optional: ["errorStage", "errorCode"]),
        .paywallShown: .init(required: ["trigger", "entitlementState"], optional: ["hadMeaningfulReading"]),
        .purchaseStart: .init(required: ["store", "productId", "trigger"], optional: []),
        .purchaseResult: .init(required: ["store", "productId", "trigger", "result"], optional: ["errorCode"]),
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
    }

    static var eventNames: Set<String> { Set(AnalyticsEventName.allCases.map(\.rawValue)) }

    private static func encodedKeys(_ properties: AnalyticsProperties) throws -> Set<String> {
        let data = try JSONEncoder().encode(properties)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set(object?.keys.map { $0 } ?? [])
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
            eventVersion: 1,
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
            struct Rejected: Decodable { let eventId: String? }
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
            let rejected = Set(body.data?.rejected?.compactMap(\.eventId) ?? [])
            return AnalyticsTransportResult(acceptedEventIds: Set(accepted), rejectedEventIds: rejected)
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
    private let transport: AnalyticsTransport
    private let batchSize: Int
    private let maxQueueSize: Int
    private var queue: [AnalyticsEventEnvelope]
    private var isFlushing = false

    init(
        store: AnalyticsQueueStore,
        transport: AnalyticsTransport,
        batchSize: Int = 20,
        maxQueueSize: Int = 500
    ) {
        self.store = store
        self.transport = transport
        self.batchSize = batchSize
        self.maxQueueSize = maxQueueSize
        self.queue = Array(store.load().suffix(maxQueueSize))
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
            variant: "app_store",
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
        intendedMode: String
    ) -> AnalyticsContentContext {
        let context = AnalyticsContentContext(
            contentSessionId: UUID().uuidString,
            source: source,
            format: format,
            entryPoint: entryPoint,
            intendedMode: intendedMode,
            startedAt: Date()
        )
        track(
            .contentIntent,
            context: .init(
                productArea: .reader,
                surface: "content_import",
                entryPoint: entryPoint,
                contentSessionId: context.contentSessionId
            ),
            properties: .init(
                contentSource: source.rawValue,
                contentFormat: format.rawValue,
                intendedMode: intendedMode
            )
        )
        return context
    }

    func contentReady(_ content: AnalyticsContentContext, document: ReadingDocument) {
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
                latencyMs: max(0, Int(Date().timeIntervalSince(content.startedAt) * 1000))
            )
        )
    }

    func contentFailed(
        _ content: AnalyticsContentContext,
        stage: String,
        code: String
    ) {
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
                latencyMs: max(0, Int(Date().timeIntervalSince(content.startedAt) * 1000)),
                result: AnalyticsResult.failed.rawValue,
                errorStage: stage,
                errorCode: code
            )
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
}
