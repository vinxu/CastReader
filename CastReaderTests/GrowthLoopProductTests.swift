//
//  GrowthLoopProductTests.swift
//  CastReaderTests
//

import XCTest
@testable import CastReader

final class GrowthLoopProductTests: XCTestCase {
    func testOutOfOrderQuotaConsumptionResponseCannotRestorePreview() {
        XCTAssertEqual(
            QuotaManager.monotonicConsumptionProjection(
                current: 120,
                reported: 180
            ),
            120
        )
        XCTAssertEqual(
            QuotaManager.monotonicConsumptionProjection(
                current: 120,
                reported: 80
            ),
            80
        )
        XCTAssertEqual(
            QuotaManager.monotonicConsumptionProjection(
                current: 0,
                reported: 300
            ),
            0
        )
    }

    private func assignment(
        market: String = "US",
        eligible: Bool = true,
        killSwitch: Bool = false,
        configID: String = "us_growth_loop_v1"
    ) -> GrowthProductAssignment {
        GrowthProductAssignment(
            configID: configID,
            market: market,
            eligible: eligible,
            killSwitch: killSwitch
        )
    }

    func testGrowthPolicyRequiresExactSignedUSAssignmentAndUSStorefront() {
        XCTAssertFalse(GrowthLoopProductPolicy.resolve(
            assignment: nil,
            storefrontCountryCode: "US"
        ).isEnabled)
        XCTAssertFalse(GrowthLoopProductPolicy.resolve(
            assignment: assignment(market: "GB"),
            storefrontCountryCode: "US"
        ).isEnabled)
        XCTAssertFalse(GrowthLoopProductPolicy.resolve(
            assignment: assignment(),
            storefrontCountryCode: "GBR"
        ).isEnabled)
        XCTAssertFalse(GrowthLoopProductPolicy.resolve(
            assignment: assignment(eligible: false),
            storefrontCountryCode: "USA"
        ).isEnabled)
        XCTAssertFalse(GrowthLoopProductPolicy.resolve(
            assignment: assignment(killSwitch: true),
            storefrontCountryCode: "USA"
        ).isEnabled)
        XCTAssertFalse(GrowthLoopProductPolicy.resolve(
            assignment: assignment(configID: "unknown_config"),
            storefrontCountryCode: "USA"
        ).isEnabled)
        XCTAssertTrue(GrowthLoopProductPolicy.resolve(
            assignment: assignment(),
            storefrontCountryCode: "USA"
        ).isEnabled)
    }

    func testActivationSourcesTreatBoundLibrariesAndEPUBPDFEqually() {
        let expected: [ReadingSourceKind: AnalyticsOnboardingSource] = [
            .kindle: .kindle,
            .weread: .weread,
            .googleBooks: .googleBooks,
            .kobo: .kobo,
            .oreilly: .oreilly,
            .epub: .file,
            .pdf: .file,
        ]
        for (source, analyticsSource) in expected {
            XCTAssertEqual(
                GrowthLoopConversionCoordinator.activationSource(for: source),
                analyticsSource
            )
        }
        for source in [
            ReadingSourceKind.text, .docx, .photo, .web, .youtube,
        ] {
            XCTAssertNil(GrowthLoopConversionCoordinator.activationSource(for: source))
        }
    }

    func testPlaybackProgressAcceptsOnlyRealTicksAndEmitsEachMilestoneOnce() {
        var progress = GrowthLoopConversionProgress()
        for _ in 0..<29 {
            XCTAssertTrue(progress.recordPlayback(1).isEmpty)
        }
        XCTAssertEqual(progress.recordPlayback(1), [.listened30Seconds])
        XCTAssertTrue(progress.recordPlayback(3).isEmpty, "seek-like delta must be ignored")
        for _ in 0..<269 {
            XCTAssertTrue(progress.recordPlayback(1).isEmpty)
        }
        XCTAssertEqual(progress.recordPlayback(1), [.listened300Seconds])
        XCTAssertTrue(progress.recordPlayback(1).isEmpty)
        XCTAssertEqual(progress.playbackSeconds, 300, accuracy: 0.001)
    }

    @MainActor
    func testUSFirstValuePathHidesHomeCardThenHardWallsExactlyOnce() throws {
        let suiteName = "GrowthLoopProductTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = GrowthLoopConversionCoordinator(
            defaults: defaults,
            storefrontCountryCode: { "US" },
            isPro: { false }
        )
        let document = ReadingDocument(
            id: "epub-first-value",
            title: "Imported EPUB",
            sourceKind: .epub,
            language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "A first paragraph")]
        )

        coordinator.applyServerAssignment(assignment())
        XCTAssertFalse(coordinator.shouldShowGenericHomeProCard(onboardingActivated: false))
        XCTAssertFalse(
            coordinator.shouldShowGenericHomeProCard(onboardingActivated: true),
            "binding alone is setup, not the 30-second first-value milestone"
        )
        coordinator.contentBecameReady(document)
        XCTAssertEqual(coordinator.softOffer?.milestone, .libraryReady)
        XCTAssertTrue(coordinator.shouldAutoplayFirstReadyContent(document))

        for _ in 0..<30 { coordinator.recordPlayback(document: document, seconds: 1) }
        XCTAssertTrue(coordinator.hasActivatedFirstValue)
        XCTAssertTrue(coordinator.shouldShowGenericHomeProCard(onboardingActivated: false))
        XCTAssertEqual(coordinator.softOffer?.milestone, .listened30Seconds)

        for _ in 30..<300 { coordinator.recordPlayback(document: document, seconds: 1) }
        var resumed = false
        XCTAssertFalse(coordinator.reclaimHardWallOnUserContinue(
            document: document,
            resumeAfterPurchase: { resumed = true }
        ), "300 seconds reached mid-paragraph may still finish that paragraph")
        XCTAssertTrue(coordinator.claimHardWallAtParagraphBoundary(
            document: document,
            resumeAfterPurchase: { resumed = true }
        ))
        XCTAssertTrue(coordinator.isPaywallPresented)
        coordinator.dismissPaywall()
        XCTAssertFalse(resumed)
        XCTAssertTrue(coordinator.reclaimHardWallOnUserContinue(
            document: document,
            resumeAfterPurchase: { resumed = true }
        ), "dismissing must not mint another preview or bypass the elapsed wall")
        XCTAssertTrue(coordinator.isPaywallPresented)
        XCTAssertFalse(resumed)
        coordinator.purchaseCompleted()
        XCTAssertTrue(resumed, "only a verified purchase may resume the reader")
        XCTAssertFalse(KindlePlaybackAccessGate.canStart(
            mode: .read,
            isPro: false,
            listenRemaining: 0,
            explainRemaining: 0
        ), "with the authoritative two-tier balance at zero, replay stays blocked")
    }

    @MainActor
    func testGBAndLegacyUsersKeepExistingHomeAndAutoplayBehavior() throws {
        let suiteName = "GrowthLoopLegacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = GrowthLoopConversionCoordinator(
            defaults: defaults,
            storefrontCountryCode: { "GB" },
            isPro: { false }
        )
        let document = ReadingDocument(
            title: "Imported PDF",
            sourceKind: .pdf,
            paragraphs: [ReadingParagraph(id: 0, text: "Page text")]
        )
        coordinator.applyServerAssignment(assignment(market: "GB"))
        coordinator.contentBecameReady(document)

        XCTAssertFalse(coordinator.policy.isEnabled)
        XCTAssertTrue(coordinator.shouldShowGenericHomeProCard(onboardingActivated: false))
        XCTAssertFalse(coordinator.shouldAutoplayFirstReadyContent(document))
        XCTAssertNil(coordinator.softOffer)
    }

    @MainActor
    func testLibraryReadyPurchaseDeliversFirstListenButDismissDoesNot() throws {
        let suiteName = "GrowthLoopPostPurchaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = GrowthLoopConversionCoordinator(
            defaults: defaults,
            storefrontCountryCode: { "US" },
            isPro: { false }
        )
        coordinator.applyServerAssignment(assignment())
        coordinator.libraryDidSync(source: .kindle)
        let offer = try XCTUnwrap(coordinator.softOffer)
        XCTAssertEqual(offer.milestone, .libraryReady)
        XCTAssertNil(offer.documentID)

        var previewStarts = 0
        coordinator.presentPaywall(
            from: offer,
            postPurchasePreview: { previewStarts += 1 }
        )
        coordinator.dismissPaywall()
        XCTAssertEqual(previewStarts, 0, "dismissing must never start a book")

        coordinator.presentPaywall(
            from: offer,
            postPurchasePreview: { previewStarts += 1 }
        )
        coordinator.purchaseCompleted()
        XCTAssertEqual(previewStarts, 1, "verified purchase must deliver the first listen")
        coordinator.purchaseCompleted()
        XCTAssertEqual(previewStarts, 1, "the post-purchase action must be one-shot")
    }

    @MainActor
    func testClearingAssignmentCannotReusePreviousAccountsContent() throws {
        let suiteName = "GrowthLoopAccountIsolationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = GrowthLoopConversionCoordinator(
            defaults: defaults,
            storefrontCountryCode: { "US" },
            isPro: { false }
        )
        let previousAccountsDocument = ReadingDocument(
            id: "previous-account-book",
            title: "Previous account title",
            sourceKind: .epub,
            language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "Private content")]
        )

        // This content is observed while no assignment exists, which is the
        // early-return edge account switching must still clear.
        coordinator.contentBecameReady(previousAccountsDocument)
        coordinator.clearServerAssignment()
        coordinator.applyServerAssignment(assignment())

        XCTAssertNil(coordinator.softOffer)
        XCTAssertFalse(coordinator.isPaywallPresented)
    }

    func testResumeReminderDeepLinkReturnsExactReadingItem() {
        let info = ResumeReminderDeepLink.userInfo(documentID: "history-42")
        XCTAssertEqual(
            ResumeReminderDeepLink.action(from: info),
            .continueReading(itemID: "history-42", mode: .read)
        )
        XCTAssertNil(ResumeReminderDeepLink.action(from: [:]))
    }

    func testResumeReminderEnqueueFailureSatisfiesAnalyticsContract() {
        XCTAssertNoThrow(try AnalyticsSchema.validate(
            .resumeReminder,
            properties: .init(
                result: AnalyticsResumeReminderOutcome.failed.rawValue,
                errorCode: "action_enqueue_failed",
                trigger: "d1_continue",
                action: AnalyticsResumeReminderAction.opened.rawValue
            )
        ))
        XCTAssertThrowsError(try AnalyticsSchema.validate(
            .resumeReminder,
            properties: .init(
                result: AnalyticsResumeReminderOutcome.failed.rawValue,
                trigger: "d1_continue",
                action: AnalyticsResumeReminderAction.opened.rawValue
            )
        ))
    }

    func testAnnualSavingsUsesActualStorefrontPrices() {
        XCTAssertEqual(
            SubscriptionPlanSavings.percentage(
                monthlyPrice: Decimal(string: "9.99")!,
                yearlyPrice: Decimal(string: "59.99")!
            ),
            50
        )
        XCTAssertNil(SubscriptionPlanSavings.percentage(
            monthlyPrice: Decimal(string: "5")!,
            yearlyPrice: Decimal(string: "60")!
        ))
    }

    func testPaywallLoginSuccessRestoresPlanAndRequiresExplicitContinueTap() throws {
        var intent = PaywallPurchaseIntentState()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let attemptID = "11111111-1111-4111-8111-111111111111"

        let gated = intent.resolveCTA(
            productId: "ai.castreader.pro.yearly.v2",
            isSignedIn: false,
            now: startedAt,
            newPurchaseAttemptId: attemptID
        )
        XCTAssertEqual(gated.action, .presentLogin)
        XCTAssertEqual(gated.purchaseAttemptId, attemptID.uppercased())
        XCTAssertNil(gated.accountGateCompletion)
        XCTAssertEqual(intent.pendingProductId, "ai.castreader.pro.yearly.v2")

        let completed = try XCTUnwrap(intent.completePresentedGate(
            isSignedIn: true,
            now: startedAt.addingTimeInterval(2.4)
        ))
        XCTAssertEqual(completed.productId, "ai.castreader.pro.yearly.v2")
        XCTAssertEqual(completed.purchaseAttemptId, gated.purchaseAttemptId)
        XCTAssertEqual(completed.result, .success)
        XCTAssertTrue(completed.gatePresented)
        XCTAssertEqual(completed.durationMs, 2_400)
        XCTAssertNil(completed.errorCode)
        XCTAssertTrue(intent.isReadyToContinue(productId: completed.productId))
        XCTAssertNil(intent.completePresentedGate(isSignedIn: true), "gate terminal must be one-shot")

        let explicitContinue = intent.resolveCTA(
            productId: completed.productId,
            isSignedIn: true
        )
        XCTAssertEqual(explicitContinue.action, .beginPurchase)
        XCTAssertEqual(
            explicitContinue.purchaseAttemptId,
            gated.purchaseAttemptId,
            "CTA, account gate and purchase continuation must share one attempt"
        )
        XCTAssertNil(
            explicitContinue.accountGateCompletion,
            "the continuation belongs to the already-recorded presented gate"
        )
        XCTAssertFalse(intent.isReadyToContinue(productId: completed.productId))
    }

    func testPaywallLoginDismissalIsTerminalAndDoesNotLeavePurchaseReady() throws {
        var intent = PaywallPurchaseIntentState()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let gated = intent.resolveCTA(
            productId: "ai.castreader.pro.monthly.v2",
            isSignedIn: false,
            now: startedAt,
            newPurchaseAttemptId: "22222222-2222-4222-8222-222222222222"
        )

        let cancelled = try XCTUnwrap(intent.completePresentedGate(
            isSignedIn: false,
            now: startedAt.addingTimeInterval(1.25)
        ))
        XCTAssertEqual(cancelled.result, .cancelled)
        XCTAssertEqual(cancelled.purchaseAttemptId, gated.purchaseAttemptId)
        XCTAssertEqual(cancelled.errorCode, "user_cancelled")
        XCTAssertEqual(cancelled.durationMs, 1_250)
        XCTAssertFalse(intent.isReadyToContinue(productId: cancelled.productId))
        XCTAssertNil(intent.completePresentedGate(isSignedIn: false))
    }

    func testRepeatedLoginPresentationKeepsOriginalGateClockAndTerminalIsIdempotent() throws {
        var intent = PaywallPurchaseIntentState()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_200)
        _ = intent.resolveCTA(
            productId: "ai.castreader.pro.yearly.v2",
            isSignedIn: false,
            now: startedAt
        )
        _ = intent.resolveCTA(
            productId: "ai.castreader.pro.yearly.v2",
            isSignedIn: false,
            now: startedAt.addingTimeInterval(5)
        )

        let completed = try XCTUnwrap(intent.completePresentedGate(
            isSignedIn: true,
            now: startedAt.addingTimeInterval(8)
        ))
        XCTAssertEqual(completed.durationMs, 8_000)
        XCTAssertNil(intent.completePresentedGate(isSignedIn: true))
    }

    func testSignedInCTAReportsNoGateAndPlanChangeClearsOldContinuation() throws {
        var intent = PaywallPurchaseIntentState()
        let direct = intent.resolveCTA(
            productId: "ai.castreader.pro.monthly.v2",
            isSignedIn: true
        )
        XCTAssertEqual(direct.action, .beginPurchase)
        XCTAssertEqual(
            direct.accountGateCompletion?.purchaseAttemptId,
            direct.purchaseAttemptId
        )
        XCTAssertEqual(direct.accountGateCompletion?.result, .success)
        XCTAssertEqual(direct.accountGateCompletion?.gatePresented, false)
        XCTAssertEqual(direct.accountGateCompletion?.durationMs, 0)

        _ = intent.resolveCTA(
            productId: "ai.castreader.pro.yearly.v2",
            isSignedIn: false,
            now: Date(timeIntervalSince1970: 1_800_000_300)
        )
        _ = try XCTUnwrap(intent.completePresentedGate(
            isSignedIn: true,
            now: Date(timeIntervalSince1970: 1_800_000_301)
        ))
        XCTAssertTrue(intent.isReadyToContinue(productId: "ai.castreader.pro.yearly.v2"))

        intent.selectedProductChanged(to: "ai.castreader.pro.monthly.v2")
        XCTAssertFalse(intent.isReadyToContinue(productId: "ai.castreader.pro.yearly.v2"))
        let changedPlan = intent.resolveCTA(
            productId: "ai.castreader.pro.monthly.v2",
            isSignedIn: true
        )
        XCTAssertEqual(changedPlan.accountGateCompletion?.gatePresented, false)
    }

    func testPaywallIntentPersistsAcrossRestartWithoutAutoPurchase() throws {
        let suiteName = "PaywallIntentRestart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPaywallPurchaseIntentStore(
            defaults: defaults,
            key: "intent"
        )
        let scope = "paywall|growth_library_ready"
        let product = "ai.castreader.pro.yearly.v2"
        let attemptID = "33333333-3333-4333-8333-333333333333"

        var beforeLogin = PaywallPurchaseIntentState()
        let cta = beforeLogin.resolveCTA(
            productId: product,
            isSignedIn: false,
            scope: scope,
            now: Date(timeIntervalSince1970: 1_800_000_400),
            newPurchaseAttemptId: attemptID
        )
        XCTAssertTrue(store.save(beforeLogin))

        var afterRestart = store.load()
        XCTAssertEqual(afterRestart.activePurchaseAttemptId, cta.purchaseAttemptId)
        let gate = try XCTUnwrap(afterRestart.completePresentedGate(
            isSignedIn: true,
            scope: scope,
            now: Date(timeIntervalSince1970: 1_800_000_402)
        ))
        XCTAssertEqual(gate.purchaseAttemptId, cta.purchaseAttemptId)
        XCTAssertTrue(store.save(afterRestart))

        var secondRestart = store.load()
        XCTAssertTrue(
            secondRestart.isReadyToContinue(productId: product, scope: scope),
            "restart may restore correlation but must not call StoreKit"
        )
        let explicitTap = secondRestart.resolveCTA(
            productId: product,
            isSignedIn: true,
            scope: scope
        )
        XCTAssertEqual(explicitTap.action, .beginPurchase)
        XCTAssertEqual(explicitTap.purchaseAttemptId, cta.purchaseAttemptId)
        XCTAssertNil(explicitTap.accountGateCompletion)
        XCTAssertTrue(secondRestart.completePurchase(
            purchaseAttemptId: explicitTap.purchaseAttemptId
        ))
        XCTAssertFalse(secondRestart.completePurchase(
            purchaseAttemptId: explicitTap.purchaseAttemptId
        ), "duplicate StoreKit callback must be idempotent")
    }

    func testInterruptedPurchaseAndPlanSwitchCannotReuseStaleAttempt() throws {
        let yearlyID = "44444444-4444-4444-8444-444444444444"
        var state = PaywallPurchaseIntentState()
        let yearly = state.resolveCTA(
            productId: "ai.castreader.pro.yearly.v2",
            isSignedIn: true,
            newPurchaseAttemptId: yearlyID
        )
        XCTAssertEqual(yearly.purchaseAttemptId, yearlyID.uppercased())
        state.discardInterruptedPurchase()
        XCTAssertNil(state.activePurchaseAttemptId)

        _ = state.resolveCTA(
            productId: "ai.castreader.pro.yearly.v2",
            isSignedIn: false,
            newPurchaseAttemptId: yearlyID
        )
        _ = try XCTUnwrap(state.completePresentedGate(isSignedIn: true))
        state.selectedProductChanged(to: "ai.castreader.pro.monthly.v2")
        XCTAssertFalse(state.isReadyToContinue(
            productId: "ai.castreader.pro.yearly.v2"
        ))
        let monthly = state.resolveCTA(
            productId: "ai.castreader.pro.monthly.v2",
            isSignedIn: true,
            newPurchaseAttemptId: "55555555-5555-4555-8555-555555555555"
        )
        XCTAssertNotEqual(monthly.purchaseAttemptId, yearly.purchaseAttemptId)
    }
}
