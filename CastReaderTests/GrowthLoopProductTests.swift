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
}
