//
//  GrowthLoopConversionCoordinator.swift
//  CastReader
//
//  Server-assigned US first-value conversion path. The server assignment is
//  deliberately required: a missing/unknown/disabled assignment always falls
//  back to the legacy product, so GB and existing users cannot accidentally
//  inherit the US preview or paywall cadence.
//

import Combine
import Foundation

struct GrowthProductAssignment: Codable, Equatable, Sendable {
    let configID: String
    let market: String
    let eligible: Bool
    let assignedAt: Date?
    let killSwitch: Bool

    init(
        configID: String,
        market: String,
        eligible: Bool,
        assignedAt: Date? = nil,
        killSwitch: Bool = false
    ) {
        self.configID = configID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.market = market.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.eligible = eligible
        self.assignedAt = assignedAt
        self.killSwitch = killSwitch
    }
}

extension GrowthProductAssignment {
    init(serverDTO: GrowthConfigDTO) {
        self.init(
            configID: serverDTO.configId,
            market: serverDTO.market,
            eligible: serverDTO.eligible,
            assignedAt: Self.parseServerDate(serverDTO.assignedAt),
            killSwitch: serverDTO.killSwitch
        )
    }

    private static func parseServerDate(_ rawValue: String?) -> Date? {
        guard let rawValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: rawValue) ?? ISO8601DateFormatter().date(from: rawValue)
    }
}

struct GrowthLoopProductPolicy: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case legacy
        case usGrowthLoop = "us_growth_loop_v1"
    }

    static let firstValueSeconds = 30.0
    static let previewSeconds = 300.0

    let mode: Mode

    var isEnabled: Bool { mode == .usGrowthLoop }
    var hidesGenericProCardBeforeFirstValue: Bool { isEnabled }
    var autoplaysFirstReadyContent: Bool { isEnabled }
    var offersAtContentReady: Bool { isEnabled }
    var offersAgainAtFirstValue: Bool { isEnabled }
    var hardWallAtPreviewBoundary: Bool { isEnabled }

    static func resolve(
        assignment: GrowthProductAssignment?,
        storefrontCountryCode: String?
    ) -> GrowthLoopProductPolicy {
        guard let assignment,
              assignment.eligible,
              !assignment.killSwitch,
              assignment.configID == Mode.usGrowthLoop.rawValue,
              assignment.market == "US",
              normalizedCountry(storefrontCountryCode) == "US" else {
            return GrowthLoopProductPolicy(mode: .legacy)
        }
        return GrowthLoopProductPolicy(mode: .usGrowthLoop)
    }

    static func normalizedCountry(_ rawValue: String?) -> String? {
        guard let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
              !value.isEmpty else { return nil }
        switch value {
        case "US", "USA": return "US"
        case "GB", "GBR", "UK": return "GB"
        default: return value
        }
    }
}

enum GrowthTrialOfferMilestone: String, Codable, Equatable, Sendable {
    case libraryReady = "library_ready"
    case listened30Seconds = "listen_30s"

    var analyticsTrigger: String {
        switch self {
        case .libraryReady: return "growth_library_ready"
        case .listened30Seconds: return "growth_listen_30s"
        }
    }
}

struct GrowthTrialOffer: Identifiable, Equatable, Sendable {
    let milestone: GrowthTrialOfferMilestone
    let source: AnalyticsOnboardingSource
    let documentID: String?
    let documentTitle: String?
    let configID: String

    var id: String {
        "\(configID)|\(milestone.rawValue)|\(source.rawValue)|\(documentID ?? "library")"
    }
}

struct GrowthLoopConversionProgress: Codable, Equatable, Sendable {
    var didReachLibraryReady = false
    var didReachFirstAudio = false
    var playbackSeconds = 0.0
    var didReach30Seconds = false
    var didReach300Seconds = false
    var didPresentHardWall = false
    var renderedOfferMilestones = Set<GrowthTrialOfferMilestone>()

    mutating func recordPlayback(_ seconds: Double) -> [AnalyticsOnboardingStep] {
        guard seconds.isFinite, seconds > 0, seconds <= 2.01 else { return [] }
        playbackSeconds = min(
            GrowthLoopProductPolicy.previewSeconds,
            playbackSeconds + seconds
        )
        var milestones: [AnalyticsOnboardingStep] = []
        if !didReach30Seconds,
           playbackSeconds >= GrowthLoopProductPolicy.firstValueSeconds {
            didReach30Seconds = true
            milestones.append(.listened30Seconds)
        }
        if !didReach300Seconds,
           playbackSeconds >= GrowthLoopProductPolicy.previewSeconds {
            didReach300Seconds = true
            milestones.append(.listened300Seconds)
        }
        return milestones
    }
}

@MainActor
final class GrowthLoopConversionCoordinator: ObservableObject {
    static let shared = GrowthLoopConversionCoordinator()

    @Published private(set) var assignment: GrowthProductAssignment?
    @Published private(set) var softOffer: GrowthTrialOffer?
    @Published private(set) var isPaywallPresented = false
    @Published private(set) var paywallTrigger = "growth_unknown"
    @Published private(set) var progress = GrowthLoopConversionProgress()

    private struct ActiveContent: Equatable {
        let documentID: String?
        let title: String?
        let source: AnalyticsOnboardingSource
    }

    private let defaults: UserDefaults
    private let storefrontCountryCode: @MainActor () -> String?
    private let isPro: @MainActor () -> Bool
    private var activeContent: ActiveContent?
    private var hardWallResume: (() -> Void)?
    private var postPurchasePreview: (() -> Void)?
    private var lastPersistedPlaybackBucket = 0

    init(
        defaults: UserDefaults = .standard,
        storefrontCountryCode: @escaping @MainActor () -> String? = {
            ProManager.shared.storefrontCountryCode
                ?? AppRegion.resolvedStorefrontCode
        },
        isPro: @escaping @MainActor () -> Bool = { ProManager.shared.isPro }
    ) {
        self.defaults = defaults
        self.storefrontCountryCode = storefrontCountryCode
        self.isPro = isPro
    }

    var policy: GrowthLoopProductPolicy {
        GrowthLoopProductPolicy.resolve(
            assignment: assignment,
            storefrontCountryCode: storefrontCountryCode()
        )
    }

    var activeConfigID: String? {
        policy.isEnabled ? assignment?.configID : nil
    }

    var hasActivatedFirstValue: Bool { progress.didReach30Seconds }

    /// Called only after a signed status response has been decoded. No local
    /// market heuristic may manufacture an assignment.
    func applyServerAssignment(_ newAssignment: GrowthProductAssignment?) {
        // Account deactivation can arrive while the assignment is already nil.
        // Always clear content/UI first so the next principal cannot inherit a
        // previous account's title, first-book action, or reader resume closure.
        if newAssignment == nil {
            activeContent = nil
            softOffer = nil
            dismissPaywall()
        }
        guard assignment != newAssignment else { return }
        assignment = newAssignment
        loadProgress()
        guard policy.isEnabled else {
            softOffer = nil
            dismissPaywall()
            return
        }
        if let activeContent, !isPro() {
            recordReadyIfNeeded(activeContent)
        }
    }

    func clearServerAssignment() {
        applyServerAssignment(nil)
    }

    func contentBecameReady(_ document: ReadingDocument) {
        guard let source = Self.activationSource(for: document.sourceKind) else { return }
        let content = ActiveContent(
            documentID: document.id,
            title: document.title.isEmpty ? nil : document.title,
            source: source
        )
        activeContent = content
        guard policy.isEnabled, !isPro() else { return }
        recordReadyIfNeeded(content)
    }

    /// Shared terminal hook for all five bound-library recorders. It can run
    /// before a concrete book/document exists; the root UI then offers either
    /// trial or a one-tap launch of the first synced book.
    func libraryDidSync(source: AnalyticsLibrarySource) {
        guard let onboardingSource = AnalyticsOnboardingSource(librarySource: source) else {
            return
        }
        let content = ActiveContent(
            documentID: nil,
            title: Self.libraryDisplayName(source),
            source: onboardingSource
        )
        activeContent = content
        guard policy.isEnabled, !isPro() else { return }
        recordReadyIfNeeded(content)
    }

    func firstAudioBecameAudible(document: ReadingDocument) {
        guard policy.isEnabled,
              !isPro(),
              Self.activationSource(for: document.sourceKind) != nil,
              !progress.didReachFirstAudio else { return }
        progress.didReachFirstAudio = true
        persistProgress()
        trackOnboarding(
            step: .firstAudio,
            result: .success,
            source: Self.activationSource(for: document.sourceKind) ?? .unknown
        )
    }

    func recordPlayback(document: ReadingDocument, seconds: Double) {
        guard policy.isEnabled,
              !isPro(),
              let source = Self.activationSource(for: document.sourceKind) else { return }
        let milestones = progress.recordPlayback(seconds)
        let bucket = Int(progress.playbackSeconds / 5)
        if bucket > lastPersistedPlaybackBucket || !milestones.isEmpty {
            lastPersistedPlaybackBucket = bucket
            persistProgress()
        }
        for milestone in milestones {
            trackOnboarding(step: milestone, result: .success, source: source)
            switch milestone {
            case .listened30Seconds:
                presentSoftOffer(
                    milestone: .listened30Seconds,
                    content: ActiveContent(
                        documentID: document.id,
                        title: document.title.isEmpty ? nil : document.title,
                        source: source
                    )
                )
            case .listened300Seconds:
                break // hard wall is intentionally claimed only at a paragraph boundary
            default:
                break
            }
        }
    }

    /// Returns true whenever the US preview has elapsed and a non-Pro user
    /// reaches a natural paragraph boundary. `didPresentHardWall` records that
    /// the wall has ever been shown, but never grants access: dismissing the
    /// sheet must remain fail-closed even if a later status refresh restores a
    /// rounded/stale balance. A long current paragraph is still allowed to
    /// finish, as promised by the product copy.
    func claimHardWallAtParagraphBoundary(
        document: ReadingDocument,
        resumeAfterPurchase: @escaping () -> Void
    ) -> Bool {
        guard policy.hardWallAtPreviewBoundary,
              !isPro(),
              Self.activationSource(for: document.sourceKind) != nil,
              progress.didReach300Seconds else { return false }
        if !progress.didPresentHardWall {
            progress.didPresentHardWall = true
            persistProgress()
        }
        softOffer = nil
        hardWallResume = resumeAfterPurchase
        postPurchasePreview = nil
        paywallTrigger = "growth_first_value_preview"
        isPaywallPresented = true
        return true
    }

    /// Reclaims an already-shown wall for an explicit play/jump/retry action.
    /// Before the first natural boundary, a pause/resume at 300 seconds must
    /// still be allowed to finish the current paragraph.
    func reclaimHardWallOnUserContinue(
        document: ReadingDocument,
        resumeAfterPurchase: @escaping () -> Void
    ) -> Bool {
        guard progress.didPresentHardWall else { return false }
        return claimHardWallAtParagraphBoundary(
            document: document,
            resumeAfterPurchase: resumeAfterPurchase
        )
    }

    func presentPaywall(
        from offer: GrowthTrialOffer,
        postPurchasePreview: (() -> Void)? = nil
    ) {
        guard policy.isEnabled, !isPro(), offer.configID == activeConfigID else { return }
        // A provider sync can finish before there is a concrete document in
        // the reader. In that one case, a successful purchase must still
        // deliver the promised first listen. Other offers already have active
        // content (or a hard-wall resume) and must not retain this callback.
        if offer.milestone == .libraryReady, offer.documentID == nil {
            self.postPurchasePreview = postPurchasePreview
        } else {
            self.postPurchasePreview = nil
        }
        paywallTrigger = offer.milestone.analyticsTrigger
        isPaywallPresented = true
    }

    func dismissSoftOffer() {
        softOffer = nil
    }

    func dismissPaywall() {
        isPaywallPresented = false
        hardWallResume = nil
        postPurchasePreview = nil
    }

    func purchaseCompleted() {
        let resume = hardWallResume ?? postPurchasePreview
        hardWallResume = nil
        postPurchasePreview = nil
        softOffer = nil
        isPaywallPresented = false
        resume?()
    }

    func shouldShowGenericHomeProCard(onboardingActivated _: Bool) -> Bool {
        guard policy.hidesGenericProCardBeforeFirstValue else { return true }
        // A connected library is a setup milestone, not value. Showing the
        // generic sales card before 30 seconds of real audio would interrupt
        // the very activation path this assignment is meant to measure.
        return progress.didReach30Seconds
    }

    func shouldAutoplayFirstReadyContent(_ document: ReadingDocument) -> Bool {
        policy.autoplaysFirstReadyContent
            && !isPro()
            && !progress.didReach30Seconds
            && Self.activationSource(for: document.sourceKind) != nil
    }

    func noteOfferRendered(_ offer: GrowthTrialOffer) {
        guard offer.configID == activeConfigID,
              !progress.renderedOfferMilestones.contains(offer.milestone) else { return }
        progress.renderedOfferMilestones.insert(offer.milestone)
        persistProgress()
        trackOnboarding(
            step: .trialOfferShown,
            result: .shown,
            source: offer.source
        )
    }

    /// Called only after StoreKit verifies a transaction that began while its
    /// product had live free-trial eligibility. A generic successful purchase
    /// must never be reclassified as a trial start.
    func storeKitFreeTrialStarted() {
        guard policy.isEnabled else { return }
        trackOnboarding(
            step: .trialStarted,
            result: .success,
            source: activeContent?.source ?? .app
        )
    }

    private func recordReadyIfNeeded(_ content: ActiveContent) {
        if !progress.didReachLibraryReady {
            progress.didReachLibraryReady = true
            persistProgress()
            trackOnboarding(
                step: .libraryReady,
                result: .success,
                source: content.source
            )
        }
        if policy.offersAtContentReady {
            presentSoftOffer(milestone: .libraryReady, content: content)
        }
    }

    private func presentSoftOffer(
        milestone: GrowthTrialOfferMilestone,
        content: ActiveContent
    ) {
        guard let configID = activeConfigID,
              !progress.renderedOfferMilestones.contains(milestone) else { return }
        softOffer = GrowthTrialOffer(
            milestone: milestone,
            source: content.source,
            documentID: content.documentID,
            documentTitle: content.title,
            configID: configID
        )
    }

    private func trackOnboarding(
        step: AnalyticsOnboardingStep,
        result: AnalyticsOnboardingOutcome,
        source: AnalyticsOnboardingSource
    ) {
        ProductAnalytics.shared.track(
            .onboardingStep,
            context: .init(
                productArea: .app,
                surface: "growth_loop",
                entryPoint: activeConfigID
            ),
            properties: .init(
                step: step.rawValue,
                source: source.rawValue,
                result: result.rawValue,
                configId: activeConfigID
            )
        )
    }

    private var progressStorageKey: String? {
        guard let configID = assignment?.configID, !configID.isEmpty else { return nil }
        return ServiceRouting.current.isolatedStorageKey(
            "growth_loop_conversion_progress.v1.\(configID)"
        )
    }

    private func loadProgress() {
        guard let key = progressStorageKey,
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(
                GrowthLoopConversionProgress.self,
                from: data
              ) else {
            progress = GrowthLoopConversionProgress()
            lastPersistedPlaybackBucket = 0
            return
        }
        progress = decoded
        lastPersistedPlaybackBucket = Int(decoded.playbackSeconds / 5)
    }

    private func persistProgress() {
        guard let key = progressStorageKey,
              let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: key)
    }

    nonisolated static func activationSource(
        for sourceKind: ReadingSourceKind
    ) -> AnalyticsOnboardingSource? {
        switch sourceKind {
        case .kindle: return .kindle
        case .weread: return .weread
        case .googleBooks: return .googleBooks
        case .kobo: return .kobo
        case .oreilly: return .oreilly
        case .pdf, .epub: return .file
        default: return nil
        }
    }

    private static func libraryDisplayName(_ source: AnalyticsLibrarySource) -> String {
        switch source {
        case .kindle: return "Kindle"
        case .weread: return AppLocalized("微信读书")
        case .googleBooks: return AppLocalized("Google Play 图书")
        case .kobo: return "Kobo"
        case .oreilly: return "O’Reilly Learning"
        }
    }
}

private extension AnalyticsOnboardingSource {
    init?(librarySource: AnalyticsLibrarySource) {
        switch librarySource {
        case .kindle: self = .kindle
        case .weread: self = .weread
        case .googleBooks: self = .googleBooks
        case .kobo: self = .kobo
        case .oreilly: self = .oreilly
        }
    }
}
