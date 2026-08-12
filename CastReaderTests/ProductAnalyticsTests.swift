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
        XCTAssertEqual(events.count, 31)
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
        XCTAssertEqual(legacy["review_prompt_eligible"], "rating_prompt_eligible")
        XCTAssertEqual(legacy["review_request_attempted"], "rating_prompt")
        XCTAssertEqual(legacy["review_store_link_opened"], "rating_store_link_opened")

        let storefrontEvents: Set<String> = [
            "content_intent", "content_ready", "content_failed",
            "read_start", "read_first_audio", "read_milestone", "read_end",
            "explain_start", "explain_first_block", "explain_milestone", "explain_end",
        ]
        for row in events where storefrontEvents.contains(row["name"] as? String ?? "") {
            let optional = Set(row["optional_properties"] as? [String] ?? [])
            XCTAssertTrue(optional.contains("storefront"), "\(row["name"] ?? "") must carry storefront")
        }

        let domains = try XCTUnwrap(object["value_domains"] as? [String: [String]])
        let contractContentSources = Set(domains["contentSource"] ?? [])
        // This contract is shared by both mobile clients. iOS must cover its
        // complete domain while retaining Android's platform-specific source
        // in the canonical cross-platform document.
        XCTAssertEqual(
            contractContentSources.subtracting(["youtube_android"]),
            Set(AnalyticsContentSource.allCases.map(\.rawValue))
        )
        XCTAssertTrue(contractContentSources.contains("youtube_android"))
        XCTAssertEqual(
            Set(domains["contentFormat"] ?? []),
            Set(AnalyticsContentFormat.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            Set(domains["librarySource"] ?? []),
            Set(AnalyticsLibrarySource.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            Set(domains["libraryConnectionStage"] ?? []),
            Set(AnalyticsLibraryConnectionStage.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            Set(domains["contentInputStage"] ?? []),
            Set(AnalyticsContentInputStage.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            domains["storefront"] ?? [],
            KindleStorefront.all.filter(\.entryEnabled).map(\.id),
            "analytics may use only the 13 entry-enabled storefront IDs"
        )
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

    func testYouTubeEventsAcceptOnlyPrivacySafeContractValues() throws {
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .contentIntent,
                properties: .init(
                    contentSource: AnalyticsContentSource.youtubeIOS.rawValue,
                    contentFormat: AnalyticsContentFormat.youtube.rawValue,
                    intendedMode: "read"
                )
            )
        )
        for entry in ["share", "clipboard", "scheme", "paste", "sample"] {
            XCTAssertNoThrow(
                try AnalyticsSchema.validate(
                    .youtubeShareReceived,
                    properties: .init(entry: entry)
                )
            )
        }
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .youtubeHomeView,
                properties: .init(firstTime: true)
            )
        )
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .youtubeExtractDone,
                properties: .init(
                    language: "zh-Hans",
                    cueCount: 120,
                    paragraphCount: 24,
                    elapsedMs: 1_234
                )
            )
        )
        for reason in [
            "no_captions",
            "live",
            "restricted",
            "unavailable",
            "caption_access",
            "player_bootstrap_failed",
            "youtube_access_limited",
            "track_unavailable",
            "timeout",
            "unsupported_language",
        ] {
            XCTAssertNoThrow(
                try AnalyticsSchema.validate(
                    .youtubeExtractFail,
                    properties: .init(reason: reason)
                )
            )
        }
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .youtubeCaptionLanguageOpen,
                properties: .init(trackCount: 4, playableTrackCount: 3)
            )
        )
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .youtubeCaptionLanguageSwitch,
                properties: .init(fromLanguage: "en", toLanguage: "ja", kind: "asr")
            )
        )
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .youtubeCaptionLanguageOpen,
                properties: .init(trackCount: 2, playableTrackCount: 5)
            ),
            "playable tracks cannot outnumber the tracks the page offered"
        )
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .youtubeCaptionLanguageSwitch,
                properties: .init(fromLanguage: "en", toLanguage: "ja", kind: "translated")
            )
        )

        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .youtubeShareReceived,
                properties: .init(entry: "https://www.youtube.com/watch?v=secret")
            )
        )
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .youtubeExtractDone,
                properties: .init(
                    language: "en",
                    cueCount: 0,
                    paragraphCount: 1,
                    elapsedMs: 10
                )
            )
        )
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .youtubeExtractFail,
                properties: .init(reason: "raw server response")
            )
        )
        XCTAssertEqual(AnalyticsContentSource.youtubeIOS.rawValue, "youtube_ios")
        XCTAssertEqual(AnalyticsContentFormat.youtube.rawValue, "youtube")
        let fallback = AnalyticsContentContext.fallback(
            for: ReadingDocument(
                title: "YouTube transcript",
                sourceKind: .youtube,
                paragraphs: []
            )
        )
        XCTAssertEqual(fallback.source, .youtubeIOS)
        XCTAssertEqual(fallback.format, .youtube)
    }

    func testHomeProCardImpressionIsNotAPaywallExposure() {
        XCTAssertEqual(
            AnalyticsEventName.homeProCardImpression.rawValue,
            "home_pro_card_impression"
        )
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .homeProCardImpression,
                properties: .init()
            )
        )
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(.paywallShown, properties: .init())
        ) { error in
            XCTAssertEqual(
                error as? AnalyticsSchemaError,
                .missingProperties(["entitlementState", "trigger"])
            )
        }
    }

    func testKindleEventsRequireAndValidateCanonicalStorefrontDimension() {
        let bindSessionId = "33333333-3333-4333-8333-333333333333"
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .contentIntent,
                properties: .init(
                    contentSource: AnalyticsContentSource.kindle.rawValue,
                    contentFormat: AnalyticsContentFormat.kindle.rawValue,
                    intendedMode: "read",
                    storefront: "es"
                )
            )
        )
        for errorCode in [
            "auth_redirect_rejected",
            "library_path_lost",
            "empty_shelf",
            "scan_timeout",
            "DOM_changed",
        ] {
            XCTAssertNoThrow(
                try AnalyticsSchema.validate(
                    .libraryConnection,
                    properties: .init(
                        source: AnalyticsLibrarySource.kindle.rawValue,
                        bindSessionId: bindSessionId,
                        stage: AnalyticsLibraryConnectionStage.failed.rawValue,
                        result: AnalyticsResult.failed.rawValue,
                        errorCode: errorCode
                    )
                ),
                errorCode
            )
        }
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .contentIntent,
                properties: .init(
                    contentSource: AnalyticsContentSource.kindle.rawValue,
                    contentFormat: AnalyticsContentFormat.kindle.rawValue,
                    intendedMode: "read"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AnalyticsSchemaError,
                .invalidPropertyValue(property: "storefront", value: "nil")
            )
        }
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .readFirstAudio,
                properties: .init(
                    latencyMs: 100,
                    language: "en",
                    voiceId: "af_heart",
                    storefront: "US"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AnalyticsSchemaError,
                .invalidPropertyValue(property: "storefront", value: "US")
            )
        }
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .contentIntent,
                properties: .init(
                    contentSource: AnalyticsContentSource.googleBooks.rawValue,
                    contentFormat: AnalyticsContentFormat.googleBooks.rawValue,
                    intendedMode: "read",
                    storefront: "us"
                )
            )
        )
    }

    func testLibraryConnectionAndContentInputStateMachines() throws {
        let bindSessionId = "33333333-3333-4333-8333-333333333333"
        for (stage, result) in [
            (AnalyticsLibraryConnectionStage.entryTapped, AnalyticsResult.started),
            (.connectionPresented, .success),
            (.loginStarted, .started),
            (.loginSucceeded, .success),
            (.syncStarted, .started),
            (.syncCompleted, .success),
            (.cancelled, .cancelled),
        ] {
            XCTAssertNoThrow(
                try AnalyticsSchema.validate(
                    .libraryConnection,
                    properties: .init(
                        source: AnalyticsLibrarySource.googleBooks.rawValue,
                        bindSessionId: bindSessionId,
                        stage: stage.rawValue,
                        durationMs: 10,
                        result: result.rawValue,
                        bookCountBucket: stage == .syncCompleted ? "6_20" : nil
                    )
                )
            )
        }
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .libraryConnection,
                properties: .init(
                    source: "google_books",
                    bindSessionId: bindSessionId,
                    stage: "failed",
                    durationMs: 20,
                    result: "failed",
                    errorCode: "navigation_failed"
                )
            )
        )
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .libraryConnection,
                properties: .init(
                    source: "google_books",
                    bindSessionId: bindSessionId,
                    stage: "sync_completed",
                    result: "started"
                )
            )
        )

        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .contentInputStage,
                properties: .init(
                    stage: "processing_started",
                    contentSource: "file",
                    contentFormat: "pdf",
                    intendedMode: "read",
                    durationMs: 1,
                    result: "started"
                )
            )
        )
    }

    func testDistributionVariantSeparatesAppStoreTestFlightAndInternalBuilds() {
        XCTAssertEqual(
            ProductAnalytics.clientVariant(
                isDebug: false,
                isSimulator: false,
                receiptLastPathComponent: "receipt",
                hasEmbeddedProvisioningProfile: false
            ),
            "app_store"
        )
        XCTAssertEqual(
            ProductAnalytics.clientVariant(
                isDebug: false,
                isSimulator: false,
                receiptLastPathComponent: "sandboxReceipt",
                hasEmbeddedProvisioningProfile: false
            ),
            "testflight"
        )
        XCTAssertEqual(
            ProductAnalytics.clientVariant(
                isDebug: false,
                isSimulator: false,
                receiptLastPathComponent: nil,
                hasEmbeddedProvisioningProfile: true
            ),
            "internal"
        )
        XCTAssertEqual(
            ProductAnalytics.clientVariant(
                isDebug: true,
                isSimulator: false,
                receiptLastPathComponent: nil,
                hasEmbeddedProvisioningProfile: true
            ),
            "internal_debug"
        )
    }

    func testKindleFallbackContextInfersStorefrontFromDocumentURL() {
        let document = ReadingDocument(
            title: "Spanish Kindle",
            sourceKind: .kindle,
            paragraphs: [],
            sourceURL: "https://leer.amazon.es/?asin=B012345678"
        )

        XCTAssertEqual(
            AnalyticsContentContext.fallback(for: document).storefront,
            "es"
        )
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

    func testReviewEventsRejectAmbiguousTriggerStoreAndResultValues() {
        for trigger in [
            "first_read_completed",
            "library_connected",
            "third_five_minute_read",
        ] {
            XCTAssertNoThrow(
                try AnalyticsSchema.validate(
                    .reviewRequestAttempted,
                    properties: .init(
                        result: "success",
                        trigger: trigger,
                        store: "app_store"
                    )
                )
            )
        }
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .reviewRequestAttempted,
                properties: .init(
                    result: "success",
                    trigger: "third_five_minute_read",
                    store: "app_store"
                )
            )
        )
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(
                .reviewRequestAttempted,
                properties: .init(
                    result: "failed",
                    errorCode: "request_unavailable",
                    trigger: "third_five_minute_read",
                    store: "app_store"
                )
            )
        )
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .reviewRequestAttempted,
                properties: .init(
                    result: "shown",
                    trigger: "third_five_minute_read",
                    store: "app_store"
                )
            )
        )
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(
                .reviewStoreLinkOpened,
                properties: .init(trigger: "third_five_minute_read", store: "app_store")
            )
        )
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

    func testServerRejectionMovesEventIntoBoundedDeadLetterWithReason() async throws {
        let store = TestQueueStore()
        let deadLetters = TestDeadLetterStore()
        let event = try makeEnvelope(name: .appSessionStart)
        let transport = RejectingTestTransport(reason: "invalid_property_value:contentSource")
        let pipeline = AnalyticsPipeline(
            store: store,
            transport: transport,
            deadLetterStore: deadLetters,
            maxDeadLetterSize: 1
        )
        await pipeline.enqueue(event)
        await pipeline.flush()

        let queued = await pipeline.queuedEvents()
        XCTAssertTrue(queued.isEmpty)
        let rejected = await pipeline.rejectedEvents()
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.eventId, fixedEventId)
        XCTAssertEqual(rejected.first?.reason, "invalid_property_value:contentSource")
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
        case .appSessionStart, .onboardingStep, .reviewPromptEligible, .reviewRequestAttempted,
             .reviewStoreLinkOpened:
            return .app
        case .libraryConnection, .contentInputStage, .contentIntent, .contentReady,
             .contentFailed, .youtubeShareReceived, .youtubeHomeView,
             .youtubeExtractDone, .youtubeExtractFail,
             .youtubeCaptionLanguageOpen, .youtubeCaptionLanguageSwitch:
            return .reader
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
        case .onboardingStep:
            return .init(step: "value", source: "kindle", result: "shown")
        case .libraryConnection:
            return .init(
                source: "google_books",
                bindSessionId: "33333333-3333-4333-8333-333333333333",
                stage: "connection_presented",
                durationMs: 20,
                result: "success"
            )
        case .contentInputStage:
            return .init(
                stage: "processing_started",
                contentSource: "file",
                contentFormat: "pdf",
                intendedMode: "read",
                durationMs: 1,
                result: "started"
            )
        case .contentIntent:
            return .init(contentSource: "file", contentFormat: "pdf", intendedMode: "read")
        case .contentReady:
            return .init(contentSource: "file", contentFormat: "pdf", lengthBucket: "500_1999", paragraphCountBucket: "6_20", latencyMs: 120)
        case .contentFailed:
            return .init(contentSource: "file", contentFormat: "pdf", latencyMs: 120, result: "failed", errorStage: "parse", errorCode: "invalid_file")
        case .youtubeShareReceived:
            return .init(entry: "share")
        case .youtubeHomeView:
            return .init(firstTime: true)
        case .youtubeExtractDone:
            return .init(language: "en", cueCount: 100, paragraphCount: 20, elapsedMs: 500)
        case .youtubeExtractFail:
            return .init(reason: "no_captions")
        case .youtubeCaptionLanguageOpen:
            return .init(trackCount: 3, playableTrackCount: 2)
        case .youtubeCaptionLanguageSwitch:
            return .init(
                elapsedMs: 900,
                fromLanguage: "en",
                toLanguage: "de",
                kind: "manual",
                cacheHit: false
            )
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
        case .reviewPromptEligible:
            return .init(trigger: "third_five_minute_read", store: "app_store")
        case .reviewRequestAttempted:
            return .init(
                result: "success",
                trigger: "third_five_minute_read",
                store: "app_store"
            )
        case .reviewStoreLinkOpened:
            return .init(trigger: "settings", store: "app_store")
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

@MainActor
final class AppReviewPromptPolicyTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testFirstPositiveOutcomeBecomesPendingImmediatelyAndOnlyOnce() {
        let policy = AppReviewPromptPolicy.production
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = AppReviewPromptState()

        XCTAssertTrue(
            policy.recordPositiveOutcome(
                in: &state,
                trigger: .firstReadCompleted,
                at: now,
                version: "1.0",
                calendar: utcCalendar
            )
        )
        XCTAssertEqual(state.pendingTrigger, .firstReadCompleted)
        XCTAssertFalse(
            policy.recordPositiveOutcome(
                in: &state,
                trigger: .libraryConnected,
                at: now,
                version: "1.0",
                calendar: utcCalendar
            ),
            "a second positive event must not replace the pending first one"
        )
        XCTAssertEqual(
            policy.consumePendingAttempt(
                in: &state,
                at: now,
                version: "1.0"
            ),
            .firstReadCompleted
        )
        XCTAssertFalse(
            policy.recordPositiveOutcome(
                in: &state,
                trigger: .libraryConnected,
                at: now.addingTimeInterval(1),
                version: "1.0",
                calendar: utcCalendar
            ),
            "the same version may call StoreKit at most once"
        )
    }

    func testThreeEarlySessionsBecomePendingWhenSeventyTwoHourGateMatures() {
        let policy = AppReviewPromptPolicy.production
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var state = AppReviewPromptState()

        policy.recordActiveDay(in: &state, at: start, calendar: utcCalendar)
        policy.recordActiveDay(
            in: &state,
            at: start.addingTimeInterval(24 * 60 * 60),
            calendar: utcCalendar
        )
        for index in 1...3 {
            XCTAssertFalse(
                policy.recordFiveMinuteReadSession(
                    in: &state,
                    sessionID: "session-\(index)",
                    at: start.addingTimeInterval(48 * 60 * 60),
                    version: "1.0",
                    calendar: utcCalendar
                )
            )
        }
        XCTAssertNil(state.pendingTrigger)

        let matured = start.addingTimeInterval(72 * 60 * 60)
        policy.recordActiveDay(in: &state, at: matured, calendar: utcCalendar)
        XCTAssertTrue(policy.evaluatePending(in: &state, at: matured, version: "1.0"))
        XCTAssertEqual(state.pendingTrigger, .thirdFiveMinuteRead)
    }

    func testEvidenceSetsStayBoundedAndSessionsAreDistinct() {
        let policy = AppReviewPromptPolicy.production
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var state = AppReviewPromptState()

        for day in 0..<20 {
            policy.recordActiveDay(
                in: &state,
                at: start.addingTimeInterval(Double(day) * 24 * 60 * 60),
                calendar: utcCalendar
            )
        }
        for id in ["a", "a", "b", "c", "d", "e"] {
            policy.recordFiveMinuteReadSession(
                in: &state,
                sessionID: id,
                at: start.addingTimeInterval(48 * 60 * 60),
                version: "1.0",
                calendar: utcCalendar
            )
        }

        XCTAssertEqual(state.activeDayIdentifiers.count, 2)
        XCTAssertEqual(state.fiveMinuteReadSessionIDs, ["a", "b", "c"])
    }

    func testReviewPlaybackDeltaRejectsSeeksAndClockAnomalies() {
        let policy = AppReviewPromptPolicy.production
        XCTAssertEqual(policy.acceptedPlaybackDelta(1.0), 1.0)
        XCTAssertEqual(policy.acceptedPlaybackDelta(2.01), 2.01)
        XCTAssertEqual(policy.acceptedPlaybackDelta(0), 0)
        XCTAssertEqual(policy.acceptedPlaybackDelta(-1), 0)
        XCTAssertEqual(policy.acceptedPlaybackDelta(20), 0)
        XCTAssertEqual(policy.acceptedPlaybackDelta(.infinity), 0)
    }

    func testFiveMinuteReadProgressSurvivesKindlePageHandoffAndRecordsOnce() {
        var firstPage = AppReviewReadSessionProgress(
            sessionID: "kindle-logical-session",
            playbackSeconds: 298
        )
        XCTAssertFalse(firstPage.record(rawPlaybackDelta: 1))

        var secondPage = firstPage
        XCTAssertTrue(secondPage.record(rawPlaybackDelta: 1))
        XCTAssertEqual(secondPage.sessionID, "kindle-logical-session")
        XCTAssertEqual(secondPage.playbackSeconds, 300, accuracy: 0.001)
        XCTAssertTrue(secondPage.didRecordFiveMinuteMilestone)
        XCTAssertFalse(secondPage.record(rawPlaybackDelta: 1))
    }

    func testFallbackAutomaticPageOwnerCarriesPagedLibrariesButManualTurnDiscards() throws {
        for sourceKind in [
            ReadingSourceKind.kindle,
            .weread,
            .googleBooks,
            .kobo,
            .oreilly
        ] {
            var firstPage = AppReviewReadSessionProgress(
                sessionID: "\(sourceKind.rawValue)-fallback-session",
                playbackSeconds: 298
            )
            XCTAssertFalse(firstPage.record(rawPlaybackDelta: 1))
            let completionToken = AppReviewAutomaticPageContinuation.candidate(
                firstPage,
                for: sourceKind
            )
            XCTAssertNotNil(completionToken)

            var owner = AppReviewAutomaticPageContinuation()
            owner.arm(try XCTUnwrap(completionToken))
            var nextPage = try XCTUnwrap(
                owner.takeForConfirmedAutomaticCommit(true)
            )
            XCTAssertTrue(nextPage.record(rawPlaybackDelta: 1))
            XCTAssertEqual(nextPage.playbackSeconds, 300, accuracy: 0.001)
            XCTAssertFalse(nextPage.record(rawPlaybackDelta: 1))
            XCTAssertNil(owner.pendingProgress, "continuation token must be one-shot")
        }

        let progress = AppReviewReadSessionProgress(
            sessionID: "manual-turn-must-reset",
            playbackSeconds: 299
        )
        var manualOwner = AppReviewAutomaticPageContinuation()
        manualOwner.arm(progress)
        XCTAssertNil(manualOwner.takeForConfirmedAutomaticCommit(false))
        XCTAssertNil(manualOwner.takeForConfirmedAutomaticCommit(true))
        XCTAssertNil(
            AppReviewAutomaticPageContinuation.candidate(progress, for: .text)
        )
    }

    func testWeReadCarryExhaustionQueuesBToCAutomaticContinuation() throws {
        var completedCarryPage = AppReviewReadSessionProgress(
            sessionID: "weread-carry-b-to-c",
            playbackSeconds: 298
        )
        XCTAssertFalse(completedCarryPage.record(rawPlaybackDelta: 1))

        var owner = AppReviewAutomaticPageContinuation()
        owner.arm(try XCTUnwrap(
            AppReviewAutomaticPageContinuation.candidate(
                completedCarryPage,
                for: .weread
            )
        ))
        let queued = owner.takeForConfirmedAutomaticCommit(true)
        var nextPage = try XCTUnwrap(
            AppReviewAutomaticPageContinuation.progressForConfirmedCommit(
                queuedProgress: queued,
                activeProgress: nil,
                isConfirmedAutomaticCommit: true,
                fallbackWillResetActiveProgress: true
            )
        )

        XCTAssertTrue(nextPage.record(rawPlaybackDelta: 1))
        XCTAssertEqual(nextPage.playbackSeconds, 300, accuracy: 0.001)
    }

    func testWeReadEarlyConfirmedFallbackSnapshotsBeforeStop() throws {
        var oldPage = AppReviewReadSessionProgress(
            sessionID: "weread-early-confirmed",
            playbackSeconds: 298
        )
        XCTAssertFalse(oldPage.record(rawPlaybackDelta: 1))

        var emptyOwner = AppReviewAutomaticPageContinuation()
        let noCompletionTokenYet = emptyOwner.takeForConfirmedAutomaticCommit(true)
        XCTAssertNil(noCompletionTokenYet)
        var fallbackPage = try XCTUnwrap(
            AppReviewAutomaticPageContinuation.progressForConfirmedCommit(
                queuedProgress: noCompletionTokenYet,
                activeProgress: oldPage,
                isConfirmedAutomaticCommit: true,
                fallbackWillResetActiveProgress: true
            )
        )
        XCTAssertTrue(fallbackPage.record(rawPlaybackDelta: 1))
        XCTAssertEqual(fallbackPage.playbackSeconds, 300, accuracy: 0.001)

        XCTAssertNil(
            AppReviewAutomaticPageContinuation.progressForConfirmedCommit(
                queuedProgress: oldPage,
                activeProgress: oldPage,
                isConfirmedAutomaticCommit: false,
                fallbackWillResetActiveProgress: true
            ),
            "manual/TOC commits must never inherit an automatic continuation"
        )
    }

    func testKindleViewModelHandoffTransfersLogicalReviewSession() throws {
        defer {
            AudioPlayerService.shared.onPlaybackComplete = nil
            if let token = AudioPlayerService.shared.activePlaybackSession {
                _ = AudioPlayerService.shared.clearQueue(session: token)
                AudioPlayerService.shared.releasePlaybackSession(token)
            }
        }
        let firstDocument = ReadingDocument(
            title: "Page 1",
            sourceKind: .kindle,
            paragraphs: [ReadingParagraph(id: 0, text: "First page.", type: .paragraph)]
        )
        let secondDocument = ReadingDocument(
            title: "Page 2",
            sourceKind: .kindle,
            paragraphs: [ReadingParagraph(id: 0, text: "Second page.", type: .paragraph)]
        )
        let expected = AppReviewReadSessionProgress(
            sessionID: "kindle-logical-session",
            playbackSeconds: 214
        )
        let firstViewModel = ReadAloudViewModel(document: firstDocument)
        XCTAssertTrue(firstViewModel.inheritAppReviewReadSession(expected))
        firstViewModel.activate()
        XCTAssertTrue(
            AudioPlayerService.shared.clearActiveQueueForCoordinator(
                owner: .readAloud
            )
        )
        let handedOff = try XCTUnwrap(firstViewModel.detachForContinuousPageHandoff())

        let secondViewModel = ReadAloudViewModel(document: secondDocument)
        XCTAssertTrue(secondViewModel.inheritAppReviewReadSession(handedOff))
        secondViewModel.activate()
        XCTAssertTrue(
            AudioPlayerService.shared.clearActiveQueueForCoordinator(
                owner: .readAloud
            )
        )
        let transferred = try XCTUnwrap(secondViewModel.detachForContinuousPageHandoff())

        XCTAssertEqual(transferred, expected)
    }

    func testKindleAnalyticsCoordinatorKeepsOneSessionAcrossPagesAndEndsOnce() throws {
        let coordinator = ReadAnalyticsSessionCoordinator()
        let firstPageOwner = UUID()
        let secondPageOwner = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var startCount = 0
        var endCount = 0

        if coordinator.begin(ownerID: firstPageOwner, at: startedAt) {
            startCount += 1
        }
        let originalSessionID = try XCTUnwrap(coordinator.sessionID)
        XCTAssertEqual(
            coordinator.markFirstAudio(ownerID: firstPageOwner),
            startedAt
        )
        _ = coordinator.accountPlayback(
            ownerID: firstPageOwner,
            segmentID: "page-1",
            position: 0
        )
        for second in 1...29 {
            _ = coordinator.accountPlayback(
                ownerID: firstPageOwner,
                segmentID: "page-1",
                position: Double(second)
            )
        }

        // The next visual page claims the existing session. It must not emit a
        // second read_start and its time/milestones continue from page one.
        XCTAssertFalse(
            coordinator.begin(
                ownerID: secondPageOwner,
                at: startedAt.addingTimeInterval(29)
            )
        )
        XCTAssertTrue(coordinator.isOwned(by: firstPageOwner))
        XCTAssertFalse(coordinator.isOwned(by: secondPageOwner))
        coordinator.seedPlaybackCursor(
            ownerID: firstPageOwner,
            segmentID: "page-2",
            position: 0
        )
        XCTAssertTrue(coordinator.claimExisting(ownerID: secondPageOwner))
        if coordinator.begin(ownerID: secondPageOwner, at: startedAt.addingTimeInterval(29)) {
            startCount += 1
        }
        XCTAssertEqual(coordinator.sessionID, originalSessionID)
        XCTAssertNil(
            coordinator.markFirstAudio(ownerID: secondPageOwner),
            "page handoff must not emit a second read_first_audio"
        )
        _ = coordinator.accountPlayback(
            ownerID: secondPageOwner,
            segmentID: "page-2",
            position: 0
        )
        for second in 1...276 {
            _ = coordinator.accountPlayback(
                ownerID: secondPageOwner,
                segmentID: "page-2",
                position: Double(second)
            )
        }

        let active = try XCTUnwrap(coordinator.activeSnapshot)
        XCTAssertEqual(active.sessionID, originalSessionID)
        XCTAssertEqual(active.playbackSeconds, 305, accuracy: 0.001)
        XCTAssertEqual(active.milestones, Set([30, 180, 300]))
        XCTAssertEqual(startCount, 1)

        // A late close/cancel from the retired page is ignored. The current
        // owner ends exactly once; repeated terminal callbacks are idempotent.
        XCTAssertNil(coordinator.end(ownerID: firstPageOwner))
        if coordinator.end(ownerID: secondPageOwner) != nil {
            endCount += 1
        }
        if coordinator.end(ownerID: secondPageOwner) != nil {
            endCount += 1
        }
        XCTAssertEqual(endCount, 1)
        XCTAssertNil(coordinator.sessionID)
    }

    func testKindleTerminalProgressRequiresExplicitEndEvidence() {
        XCTAssertTrue(KindleTurnContract.isTerminalProgress("100%"))
        XCTAssertTrue(KindleTurnContract.isTerminalProgress("Page 12 of 12"))
        XCTAssertTrue(KindleTurnContract.isTerminalProgress("第 １２ / １２ 页"))
        XCTAssertFalse(KindleTurnContract.isTerminalProgress("99%"))
        XCTAssertFalse(KindleTurnContract.isTerminalProgress("Page 11 of 12"))
        XCTAssertFalse(KindleTurnContract.isTerminalProgress(nil))

        XCTAssertFalse(
            KindleTurnContract.isTerminalPage(
                liveProgress: "99%",
                storedProgress: "100%"
            ),
            "a live non-terminal value must override stale persisted progress"
        )
        XCTAssertTrue(
            KindleTurnContract.isTerminalPage(
                liveProgress: nil,
                storedProgress: "Location 400 of 400"
            )
        )
    }

    func testReviewPresentationGateBlocksStreamingGapsAndHomeProcessing() {
        XCTAssertTrue(AppReviewPresentationGate.playbackIsQuiescent(
            isPlaying: false,
            isBuffering: false,
            moreSegmentsExpected: false,
            isWaitingForNextSegment: false
        ))
        XCTAssertFalse(AppReviewPresentationGate.playbackIsQuiescent(
            isPlaying: false,
            isBuffering: false,
            moreSegmentsExpected: true,
            isWaitingForNextSegment: true
        ))
        XCTAssertFalse(AppReviewPresentationGate.playbackIsQuiescent(
            isPlaying: false,
            isBuffering: true,
            moreSegmentsExpected: false,
            isWaitingForNextSegment: false
        ))

        func gate(homeIsIdle: Bool) -> AppReviewPresentationGate {
            AppReviewPresentationGate(
                pending: true,
                appIsActive: true,
                isHome: true,
                playbackIsQuiescent: true,
                readerIsHidden: true,
                kindleReaderIsHidden: true,
                importChromeIsVisible: true,
                homeIsIdle: homeIsIdle,
                clipboardSheetIsHidden: true,
                shareInboxIsHidden: true,
                voiceCloneSheetIsHidden: true,
                voicePanelIsHidden: true,
                onboardingIsHidden: true
            )
        }

        XCTAssertTrue(gate(homeIsIdle: true).canStabilize)
        XCTAssertFalse(gate(homeIsIdle: false).canStabilize)
    }

    func testVersionCooldownAndRollingYearFrequencyCaps() {
        let policy = AppReviewPromptPolicy.production
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var state = AppReviewPromptState(
            firstRecordedAt: start,
            activeDayIdentifiers: ["2023-11-14", "2023-11-15"],
            fiveMinuteReadSessionIDs: ["a", "b", "c"]
        )
        let firstAttemptAt = start.addingTimeInterval(3 * day)

        XCTAssertTrue(policy.evaluatePending(in: &state, at: firstAttemptAt, version: "1.0"))
        XCTAssertEqual(
            policy.consumePendingAttempt(in: &state, at: firstAttemptAt, version: "1.0"),
            .thirdFiveMinuteRead
        )
        XCTAssertFalse(policy.evaluatePending(
            in: &state,
            at: firstAttemptAt.addingTimeInterval(365 * day),
            version: "1.0"
        ), "同版本永远只允许一次")
        XCTAssertFalse(policy.evaluatePending(
            in: &state,
            at: firstAttemptAt.addingTimeInterval(89 * day),
            version: "1.1"
        ))

        let secondAt = firstAttemptAt.addingTimeInterval(90 * day)
        XCTAssertTrue(policy.evaluatePending(in: &state, at: secondAt, version: "1.1"))
        XCTAssertNotNil(policy.consumePendingAttempt(in: &state, at: secondAt, version: "1.1"))

        let thirdAt = secondAt.addingTimeInterval(90 * day)
        XCTAssertTrue(policy.evaluatePending(in: &state, at: thirdAt, version: "1.2"))
        XCTAssertNotNil(policy.consumePendingAttempt(in: &state, at: thirdAt, version: "1.2"))

        let cappedAt = thirdAt.addingTimeInterval(90 * day)
        XCTAssertFalse(policy.evaluatePending(in: &state, at: cappedAt, version: "1.3"))

        let rollingWindowPassed = firstAttemptAt.addingTimeInterval(366 * day)
        XCTAssertTrue(policy.evaluatePending(
            in: &state,
            at: rollingWindowPassed,
            version: "1.3"
        ))
        XCTAssertLessThanOrEqual(state.attempts.count, 3)
    }

    func testManagerPersistsPendingAndCountsAttemptAtStoreKitCall() throws {
        let suite = "AppReviewPromptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var currentDate = start
        var events: [AnalyticsEventName] = []
        let manager = AppReviewPromptManager(
            defaults: defaults,
            calendar: utcCalendar,
            now: { currentDate },
            version: { "1.0" },
            analyticsRecorder: { name, _, _ in events.append(name) }
        )
        manager.recordActiveDay()
        currentDate = start.addingTimeInterval(24 * 60 * 60)
        manager.recordActiveDay()
        currentDate = start.addingTimeInterval(72 * 60 * 60)
        for index in 1...3 {
            manager.recordFiveMinuteReadSession(sessionID: "session-\(index)")
        }

        XCTAssertEqual(manager.pendingTrigger, .thirdFiveMinuteRead)
        XCTAssertEqual(events, [.reviewPromptEligible])
        manager.recordActiveDay()
        manager.recordActiveDay()
        XCTAssertEqual(
            events,
            [.reviewPromptEligible],
            "pending eligibility must be emitted exactly once"
        )

        var restoredEvents: [(AnalyticsEventName, AnalyticsProperties)] = []
        let restored = AppReviewPromptManager(
            defaults: defaults,
            calendar: utcCalendar,
            now: { currentDate },
            version: { "1.0" },
            analyticsRecorder: { name, _, properties in
                restoredEvents.append((name, properties))
            }
        )
        XCTAssertEqual(restored.pendingTrigger, .thirdFiveMinuteRead)

        var requestCalls = 0
        XCTAssertTrue(restored.performSystemReviewRequest { requestCalls += 1 })
        XCTAssertEqual(requestCalls, 1)
        XCTAssertEqual(restored.snapshot.attempts.count, 1)
        XCTAssertEqual(restoredEvents.map { $0.0 }, [.reviewRequestAttempted])
        XCTAssertEqual(restoredEvents.first?.1.result, "success")
        XCTAssertFalse(restored.performSystemReviewRequest { requestCalls += 1 })
        XCTAssertEqual(requestCalls, 1)
    }

    func testReviewSettingsStringsCoverAllNineRuntimeLanguages() {
        let keys = ["支持与反馈", "评价 CastReader", "发送反馈"]
        for language in AppLanguage.allCases where language != .system {
            guard let localization = language.bundleLocalization,
                  let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return XCTFail("Missing runtime bundle for \(language.rawValue)")
            }
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertFalse(value.isEmpty, "Empty review translation for \(language.rawValue): \(key)")
                if language != .simplifiedChinese {
                    XCTAssertNotEqual(
                        value,
                        key,
                        "Missing review translation for \(language.rawValue): \(key)"
                    )
                }
            }
        }
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

private final class TestDeadLetterStore: AnalyticsDeadLetterStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [AnalyticsDeadLetterRecord] = []

    func load() -> [AnalyticsDeadLetterRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func save(_ records: [AnalyticsDeadLetterRecord]) {
        lock.lock()
        self.records = records
        lock.unlock()
    }
}

private actor RejectingTestTransport: AnalyticsTransport {
    let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func send(_ events: [AnalyticsEventEnvelope]) async throws -> AnalyticsTransportResult {
        let ids = Set(events.map(\.eventId))
        return AnalyticsTransportResult(
            acceptedEventIds: [],
            rejectedEventIds: ids,
            rejectionReasons: Dictionary(uniqueKeysWithValues: ids.map { ($0, reason) })
        )
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
