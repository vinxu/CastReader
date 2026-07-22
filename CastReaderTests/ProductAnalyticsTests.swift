import XCTest
@testable import CastReader

final class ProductAnalyticsTests: XCTestCase {
    func testCanonicalContractMatchesIOSCasesAndLegacyMappings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contractURL = root.appendingPathComponent("docs/analytics/mobile-events-v2.json")
        guard FileManager.default.fileExists(atPath: contractURL.path) else {
            throw XCTSkip("工程内 analytics 合同仅在 host 测试环境可读")
        }
        let data = try Data(contentsOf: contractURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let names = Set(events.compactMap { $0["name"] as? String })
        let legacy = Dictionary(uniqueKeysWithValues: events.compactMap { row -> (String, String)? in
            guard let name = row["name"] as? String,
                  let legacy = row["legacy_event"] as? String else { return nil }
            return (name, legacy)
        })

        XCTAssertEqual(names, AnalyticsSchema.eventNames)
        for name in AnalyticsEventName.allCases {
            XCTAssertEqual(legacy[name.rawValue], name.legacyEvent)
        }
        let purchaseRow = try XCTUnwrap(events.first { $0["name"] as? String == "purchase_result" })
        let purchaseLegacy = try XCTUnwrap(purchaseRow["legacy_event_by_result"] as? [String: String])
        XCTAssertEqual(purchaseLegacy["success"], "checkout_completed")
        XCTAssertEqual(purchaseLegacy["cancelled"], "checkout_return_cancel")
        XCTAssertEqual(purchaseLegacy["pending"], "checkout_error")
        XCTAssertEqual(purchaseLegacy["blocked"], "checkout_error")
        XCTAssertEqual(purchaseLegacy["failed"], "checkout_error")
    }

    func testEveryEventBuildsAValidDualEnvelope() throws {
        for name in AnalyticsEventName.allCases {
            let envelope = try makeEnvelope(name: name)
            XCTAssertEqual(envelope.eventName, name)
            XCTAssertEqual(envelope.eventId, fixedEventId)
            XCTAssertEqual(envelope.deviceId, envelope.anonymousId)
            XCTAssertEqual(envelope.timestamp, envelope.occurredAt)
            XCTAssertFalse(envelope.event.isEmpty)
            XCTAssertEqual(envelope.eventVersion, 2)
        }
    }

    func testSchemaRejectsMissingAndUnknownProperties() throws {
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(.readFirstAudio, properties: .init(language: "en", voiceId: "af_heart"))
        ) { error in
            XCTAssertEqual(error as? AnalyticsSchemaError, .missingProperties(["latencyMs"]))
        }

        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .appSessionStart,
                properties: .init(launchType: "cold", language: "en")
            )
        ) { error in
            XCTAssertEqual(error as? AnalyticsSchemaError, .unknownProperties(["language"]))
        }
    }

    func testPurchaseResultUsesOutcomeSpecificLegacyEvent() throws {
        let success = try makeEnvelope(name: .purchaseResult, properties: purchaseResult(.success))
        let cancelled = try makeEnvelope(name: .purchaseResult, properties: purchaseResult(.cancelled))
        let pending = try makeEnvelope(name: .purchaseResult, properties: purchaseResult(.pending))
        let blocked = try makeEnvelope(name: .purchaseResult, properties: purchaseResult(.blocked))
        let failed = try makeEnvelope(name: .purchaseResult, properties: purchaseResult(.failed))
        XCTAssertEqual(success.event, "checkout_completed")
        XCTAssertEqual(cancelled.event, "checkout_return_cancel")
        XCTAssertEqual(pending.event, "checkout_error")
        XCTAssertEqual(blocked.event, "checkout_error")
        XCTAssertEqual(failed.event, "checkout_error")
    }

    func testQueueRetainsOriginalEventIDAcrossFailureAndRestart() async throws {
        let store = TestQueueStore()
        let failing = TestTransport(failuresRemaining: 1)
        let event = try makeEnvelope(name: .appSessionStart)
        let firstPipeline = AnalyticsPipeline(store: store, transport: failing, batchSize: 20)

        await firstPipeline.enqueue(event)
        await firstPipeline.flush()
        let retainedAfterFailure = await firstPipeline.queuedEvents().map(\.eventId)
        XCTAssertEqual(retainedAfterFailure, [fixedEventId])

        let succeeding = TestTransport(failuresRemaining: 0)
        let restartedPipeline = AnalyticsPipeline(store: store, transport: succeeding, batchSize: 20)
        let restored = await restartedPipeline.queuedEvents().map(\.eventId)
        XCTAssertEqual(restored, [fixedEventId])
        await restartedPipeline.flush()

        let finalQueue = await restartedPipeline.queuedEvents()
        let sent = await succeeding.sentEventIDs()
        XCTAssertTrue(finalQueue.isEmpty)
        XCTAssertEqual(sent, [fixedEventId])
    }

    func testQueueDeduplicatesSameEventID() async throws {
        let store = TestQueueStore()
        let transport = TestTransport(failuresRemaining: 1)
        let pipeline = AnalyticsPipeline(store: store, transport: transport, batchSize: 20)
        let event = try makeEnvelope(name: .appSessionStart)
        await pipeline.enqueue(event)
        await pipeline.enqueue(event)
        let count = await pipeline.queuedEvents().count
        XCTAssertEqual(count, 1)
    }

    func testCompletionBuckets() {
        XCTAssertEqual(ProductAnalytics.completionBucket(completed: 0, total: 10), "none")
        XCTAssertEqual(ProductAnalytics.completionBucket(completed: 2, total: 10), "lt_25")
        XCTAssertEqual(ProductAnalytics.completionBucket(completed: 5, total: 10), "50_79")
        XCTAssertEqual(ProductAnalytics.completionBucket(completed: 8, total: 10), "80_99")
        XCTAssertEqual(ProductAnalytics.completionBucket(completed: 10, total: 10), "complete")
    }

    func testMeaningfulExplainBlockThresholdIsEightyPercent() {
        XCTAssertFalse(ProductAnalytics.isMeaningfulExplainBlockProgress(0.7999))
        XCTAssertTrue(ProductAnalytics.isMeaningfulExplainBlockProgress(0.8))
        XCTAssertTrue(ProductAnalytics.isMeaningfulExplainBlockProgress(1.0))
    }

    private let fixedEventId = "11111111-1111-1111-1111-111111111111"

    private func makeEnvelope(
        name: AnalyticsEventName,
        properties: AnalyticsProperties? = nil
    ) throws -> AnalyticsEventEnvelope {
        try AnalyticsEnvelopeFactory.make(
            name: name,
            context: AnalyticsEventContext(
                productArea: area(for: name),
                surface: "unit_test",
                entryPoint: "unit_test",
                contentSessionId: "content-session",
                readSessionId: name.rawValue.hasPrefix("read_") ? "read-session" : nil,
                explainSessionId: name.rawValue.hasPrefix("explain_") ? "explain-session" : nil,
                purchaseAttemptId: name.rawValue.hasPrefix("purchase_") ? "purchase-session" : nil
            ),
            properties: properties ?? validProperties(for: name),
            client: AnalyticsClientInfo(
                environment: "test",
                platform: "ios",
                variant: "unit_test",
                version: "1.0",
                build: "1",
                anonymousId: "22222222-2222-2222-2222-222222222222"
            ),
            appSessionId: "app-session",
            backendUserId: "backend-user",
            eventId: fixedEventId,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func area(for name: AnalyticsEventName) -> AnalyticsProductArea {
        switch name {
        case .appSessionStart: return .app
        case .contentIntent, .contentReady, .contentFailed: return .reader
        case .readStart, .readFirstAudio, .readMilestone, .readEnd: return .readAloud
        case .explainStart, .explainFirstBlock, .explainMilestone, .explainEnd: return .explain
        case .paywallShown, .homeProCardImpression, .homeProCardYearlyPurchaseTap,
             .homeProCardSecondaryTap, .purchaseStart, .purchaseResult,
             .entitlementActivated:
            return .billing
        }
    }

    private func validProperties(for name: AnalyticsEventName) -> AnalyticsProperties {
        switch name {
        case .appSessionStart:
            return .init(launchType: "cold")
        case .contentIntent:
            return .init(contentSource: "file", contentFormat: "pdf", intendedMode: "read")
        case .contentReady:
            return .init(contentSource: "file", contentFormat: "pdf", lengthBucket: "500_1999", paragraphCountBucket: "6_20", latencyMs: 120)
        case .contentFailed:
            return .init(contentSource: "file", contentFormat: "pdf", latencyMs: 120, result: "failed", errorStage: "parse", errorCode: "invalid_file")
        case .readStart:
            return .init(contentSource: "file", contentFormat: "pdf", language: "en", voiceId: "af_heart", speed: 1, resume: false)
        case .readFirstAudio:
            return .init(latencyMs: 220, language: "en", voiceId: "af_heart")
        case .readMilestone:
            return .init(milestoneSeconds: 300, playbackSeconds: 300, completionBucket: "50_79")
        case .readEnd:
            return .init(result: "success", playbackSeconds: 320, completionBucket: "complete", endReason: "completed")
        case .explainStart:
            return .init(contentSource: "file", contentFormat: "pdf", language: "en", scenario: "paper")
        case .explainFirstBlock:
            return .init(latencyMs: 900, scenario: "paper")
        case .explainMilestone:
            return .init(milestone: "first_block_completed", blocksStarted: 1, blocksCompleted: 1)
        case .explainEnd:
            return .init(result: "success", completionBucket: "complete", endReason: "completed", blocksStarted: 2, blocksCompleted: 2)
        case .paywallShown:
            return .init(trigger: "listen_quota", entitlementState: "free", hadMeaningfulReading: true)
        case .homeProCardImpression, .homeProCardYearlyPurchaseTap, .homeProCardSecondaryTap:
            return .init()
        case .purchaseStart:
            return .init(trigger: "listen_quota", store: "app_store", productId: "ai.castreader.pro.monthly")
        case .purchaseResult:
            return purchaseResult(.success)
        case .entitlementActivated:
            return .init(
                trigger: "listen_quota",
                store: "app_store",
                productId: "ai.castreader.pro.monthly",
                activationSource: "storekit_verified"
            )
        }
    }

    private func purchaseResult(_ result: AnalyticsResult) -> AnalyticsProperties {
        .init(
            result: result.rawValue,
            trigger: "listen_quota",
            store: "app_store",
            productId: "ai.castreader.pro.monthly"
        )
    }
}

private final class TestQueueStore: AnalyticsQueueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AnalyticsEventEnvelope] = []

    func load() -> [AnalyticsEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func save(_ events: [AnalyticsEventEnvelope]) {
        lock.lock()
        self.events = events
        lock.unlock()
    }
}

private actor TestTransport: AnalyticsTransport {
    enum Failure: Error { case offline }
    private var failuresRemaining: Int
    private var sent: [String] = []

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func send(_ events: [AnalyticsEventEnvelope]) async throws -> AnalyticsTransportResult {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Failure.offline
        }
        let ids = events.map(\.eventId)
        sent.append(contentsOf: ids)
        return AnalyticsTransportResult(acceptedEventIds: Set(ids), rejectedEventIds: [])
    }

    func sentEventIDs() -> [String] { sent }
}
