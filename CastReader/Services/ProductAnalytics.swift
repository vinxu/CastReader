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
    case appFirstOpen = "app_first_open"
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
    case paywallAction = "paywall_action"
    case accountGateResult = "account_gate_result"
    case homeProCardImpression = "home_pro_card_impression"
    case homeProCardYearlyPurchaseTap = "home_pro_card_yearly_purchase_tap"
    case homeProCardSecondaryTap = "home_pro_card_secondary_tap"
    case purchaseStart = "purchase_start"
    case purchaseResult = "purchase_result"
    case entitlementActivated = "entitlement_activated"
    case reviewPromptEligible = "review_prompt_eligible"
    case reviewRequestAttempted = "review_request_attempted"
    case reviewStoreLinkOpened = "review_store_link_opened"
    case adAttributionAttempt = "ad_attribution_attempt"
    case adAttribution = "ad_attribution"
    case growthConfigAssigned = "growth_config_assigned"
    case paywallPlanSelected = "paywall_plan_selected"
    case resumeReminder = "resume_reminder"

    var legacyEvent: String {
        switch self {
        case .appSessionStart: return "session_start"
        case .appFirstOpen: return "app_first_open"
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
        case .paywallAction: return "paywall_action"
        case .accountGateResult: return "account_gate_result"
        case .homeProCardImpression: return "home_pro_card_impression"
        case .homeProCardYearlyPurchaseTap: return "home_pro_card_yearly_purchase_tap"
        case .homeProCardSecondaryTap: return "home_pro_card_secondary_tap"
        case .purchaseStart: return "checkout_started"
        case .purchaseResult: return "checkout_completed"
        case .entitlementActivated: return "pro_activated"
        case .reviewPromptEligible: return "rating_prompt_eligible"
        case .reviewRequestAttempted: return "rating_prompt"
        case .reviewStoreLinkOpened: return "rating_store_link_opened"
        case .adAttributionAttempt: return "ad_attribution_attempt"
        case .adAttribution: return "ad_attribution"
        case .growthConfigAssigned: return "growth_config_assigned"
        case .paywallPlanSelected: return "paywall_plan_selected"
        case .resumeReminder: return "resume_reminder"
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

enum AnalyticsOnboardingStep: String, Codable, CaseIterable, Sendable {
    case authGateViewed = "auth_gate_viewed"
    case authProviderTapped = "auth_provider_tapped"
    case authSucceeded = "auth_succeeded"
    case authFailed = "auth_failed"
    case sourceChooserShown = "source_chooser_shown"
    case sourceSelected = "source_selected"
    case libraryReady = "library_ready"
    case firstBookOpened = "first_book_opened"
    case firstAudio = "first_audio"
    case listened30Seconds = "listen_30s"
    case listened300Seconds = "listen_300s"
    case trialOfferShown = "trial_offer_shown"
    case trialStarted = "trial_started"
    // Android storefront onboarding values are part of the shared canonical
    // contract even though iOS does not currently emit them.
    case value
    case storefront
    case login
    case scan
    case firstListen = "first_listen"
}

enum AnalyticsFirstOpenKind: String, Codable, CaseIterable, Sendable {
    case freshInstall = "fresh_install"
    case instrumentationBackfill = "instrumentation_backfill"
    case unknown
}

enum AnalyticsOnboardingOutcome: String, Codable, CaseIterable, Sendable {
    case shown
    case tapped
    case started
    case success
    case failed
    case skipped
    case done
}

enum AnalyticsOnboardingSource: String, Codable, CaseIterable, Sendable {
    case app
    case apple
    case google
    case email
    case phone
    case kindle
    case weread
    case googleBooks = "google_books"
    case kobo
    case oreilly
    case file
    case camera
    case photoLibrary = "photo_library"
    case clipboard
    case url
    case text
    case unknown
    case other
}

enum AnalyticsAdAttributionAttemptOutcome: String, Codable, CaseIterable, Sendable {
    case tokenAcquired = "token_acquired"
    case referrerAcquired = "referrer_acquired"
    case retryableError = "retryable_error"
    case unsupported
    case failed
    case windowExpired = "window_expired"
    case deliveryNotAccepted = "delivery_not_accepted"
}

enum AnalyticsGrowthEligibility: String, Codable, CaseIterable, Sendable {
    case eligible
    case ineligible
}

enum AnalyticsGrowthMarket: String, Codable, CaseIterable, Sendable {
    case us
    case gb
    case other
}

enum AnalyticsPlanSelectionSource: String, Codable, CaseIterable, Sendable {
    case defaultSelection = "default"
    case user
}

enum AnalyticsPlanInterval: String, Codable, CaseIterable, Sendable {
    case monthly
    case yearly
}

enum AnalyticsPaywallAction: String, Codable, CaseIterable, Sendable {
    case ctaTapped = "cta_tapped"
    case dismissed
}

enum AnalyticsAccountGateResult: String, Codable, CaseIterable, Sendable {
    case success
    case cancelled
    case failed
}

enum AnalyticsOfferType: String, Codable, CaseIterable, Sendable {
    case introductory
    case promotional
    case code
    case other
    case none
}

enum AnalyticsResumeReminderAction: String, Codable, CaseIterable, Sendable {
    case permissionRequested = "permission_requested"
    case scheduled
    case opened
    case cancelled
}

enum AnalyticsResumeReminderOutcome: String, Codable, CaseIterable, Sendable {
    case success
    case denied
    case failed
    case unavailable
    case cancelled
}

enum AnalyticsNotificationPermissionStatus: String, Codable, CaseIterable, Sendable {
    case notDetermined = "not_determined"
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown
}

/// How a session started. The three system-surface values mirror
/// `SystemActionOrigin`, which lives in the extension-safe SystemIntegration
/// module and therefore cannot import this file; `SystemIntegrationTests`
/// pins the two vocabularies together.
enum AnalyticsLaunchType: String, Codable, CaseIterable, Sendable {
    /// Ordinary launch — icon tap, or the app being restored by the system.
    case cold
    /// Same process returning to foreground after the session window expired.
    case foregroundAfter30m = "foreground_after_30m"
    /// Siri, Spotlight, Shortcuts or the Action Button ran an App Intent.
    case intent
    /// A widget button or link.
    case widget
    /// A `castreader://` URL.
    case deepLink = "deep_link"
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
    var provider: String?
    var attributionResult: String?
    var attributionToken: String?
    var attemptCount: Int?
    var offerType: String?
    var outcome: String?
    var configId: String?
    var market: String?
    var eligibility: String?
    var valueMilestone: String?
    var offerEligible: Bool?
    var selectedProductId: String?
    var selectionSource: String?
    var interval: String?
    var action: String?
    var permissionStatus: String?
    var daysSinceLastRead: Int?
    var firstOpenKind: String?
    var campaignSource: String?
    var campaignMedium: String?
    var landingTouchId: String?
    var campaignId: String?
    var adGroupId: String?
    var creativeId: String?
    var choiceSurface: String?
    var recommendationSignal: String?
    var matched: Bool?
    var gatePresented: Bool?
    var trialDays: Int?

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
        storefront: String? = nil,
        provider: String? = nil,
        attributionResult: String? = nil,
        attributionToken: String? = nil,
        attemptCount: Int? = nil,
        offerType: String? = nil,
        outcome: String? = nil,
        configId: String? = nil,
        market: String? = nil,
        eligibility: String? = nil,
        valueMilestone: String? = nil,
        offerEligible: Bool? = nil,
        selectedProductId: String? = nil,
        selectionSource: String? = nil,
        interval: String? = nil,
        action: String? = nil,
        permissionStatus: String? = nil,
        daysSinceLastRead: Int? = nil,
        firstOpenKind: String? = nil,
        campaignSource: String? = nil,
        campaignMedium: String? = nil,
        landingTouchId: String? = nil,
        campaignId: String? = nil,
        adGroupId: String? = nil,
        creativeId: String? = nil,
        choiceSurface: String? = nil,
        recommendationSignal: String? = nil,
        matched: Bool? = nil,
        gatePresented: Bool? = nil,
        trialDays: Int? = nil
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
        self.provider = provider
        self.attributionResult = attributionResult
        self.attributionToken = attributionToken
        self.attemptCount = attemptCount
        self.offerType = offerType
        self.outcome = outcome
        self.configId = configId
        self.market = market
        self.eligibility = eligibility
        self.valueMilestone = valueMilestone
        self.offerEligible = offerEligible
        self.selectedProductId = selectedProductId
        self.selectionSource = selectionSource
        self.interval = interval
        self.action = action
        self.permissionStatus = permissionStatus
        self.daysSinceLastRead = daysSinceLastRead
        self.firstOpenKind = firstOpenKind
        self.campaignSource = campaignSource
        self.campaignMedium = campaignMedium
        self.landingTouchId = landingTouchId
        self.campaignId = campaignId
        self.adGroupId = adGroupId
        self.creativeId = creativeId
        self.choiceSurface = choiceSurface
        self.recommendationSignal = recommendationSignal
        self.matched = matched
        self.gatePresented = gatePresented
        self.trialDays = trialDays
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

/// Minimal, privacy-safe business receipt for a provider-verified, non-empty
/// shelf sync. It exists because the generic analytics queue is actor-owned:
/// calling it from a synchronous shelf commit otherwise leaves a kill-process
/// window before the event is durably enqueued. The receipt is removed only
/// after the collector acknowledges this exact event id.
struct AnalyticsLibrarySyncReceiptV1: Codable, Equatable, Identifiable, Sendable {
    let eventId: String
    let bindSessionId: String
    let source: AnalyticsLibrarySource
    let entryPoint: String
    let startedAt: Date
    let occurredAt: Date
    let bookCount: Int

    var id: String { eventId }
}

enum AnalyticsLibrarySyncReceiptStoreError: Error, Equatable {
    case corruptState
    case conflictingBindSession
    case persistenceFailed
}

protocol AnalyticsLibrarySyncReceiptStoring: Sendable {
    func load() throws -> [AnalyticsLibrarySyncReceiptV1]
    func persist(
        _ receipt: AnalyticsLibrarySyncReceiptV1
    ) throws -> AnalyticsLibrarySyncReceiptV1
    func remove(eventId: String) throws
}

final class UserDefaultsAnalyticsLibrarySyncReceiptStore:
    AnalyticsLibrarySyncReceiptStoring,
    @unchecked Sendable
{
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        key: String = "library_sync_receipts_v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> [AnalyticsLibrarySyncReceiptV1] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func persist(
        _ receipt: AnalyticsLibrarySyncReceiptV1
    ) throws -> AnalyticsLibrarySyncReceiptV1 {
        lock.lock()
        defer { lock.unlock() }
        var receipts = try loadUnlocked()
        if let existing = receipts.first(where: {
            $0.bindSessionId == receipt.bindSessionId
        }) {
            guard existing.eventId == receipt.eventId,
                  existing.source == receipt.source,
                  existing.entryPoint == receipt.entryPoint else {
                throw AnalyticsLibrarySyncReceiptStoreError.conflictingBindSession
            }
            return existing
        }
        receipts.append(receipt)
        try saveUnlocked(receipts)
        guard try loadUnlocked().contains(receipt) else {
            throw AnalyticsLibrarySyncReceiptStoreError.persistenceFailed
        }
        return receipt
    }

    func remove(eventId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var receipts = try loadUnlocked()
        receipts.removeAll { $0.eventId == eventId }
        try saveUnlocked(receipts)
    }

    private func loadUnlocked() throws -> [AnalyticsLibrarySyncReceiptV1] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let receipts = try? JSONDecoder().decode(
            [AnalyticsLibrarySyncReceiptV1].self,
            from: data
        ) else {
            throw AnalyticsLibrarySyncReceiptStoreError.corruptState
        }
        return receipts
    }

    private func saveUnlocked(_ receipts: [AnalyticsLibrarySyncReceiptV1]) throws {
        if receipts.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            guard let data = try? JSONEncoder().encode(receipts) else {
                throw AnalyticsLibrarySyncReceiptStoreError.persistenceFailed
            }
            defaults.set(data, forKey: key)
        }
        guard defaults.synchronize() else {
            throw AnalyticsLibrarySyncReceiptStoreError.persistenceFailed
        }
    }
}

protocol AnalyticsLibrarySyncReporting: Sendable {
    func recordLibrarySync(
        _ receipt: AnalyticsLibrarySyncReceiptV1
    ) async -> AnalyticsDeliveryDisposition
}

struct ProductAnalyticsLibrarySyncReporter: AnalyticsLibrarySyncReporting {
    func recordLibrarySync(
        _ receipt: AnalyticsLibrarySyncReceiptV1
    ) async -> AnalyticsDeliveryDisposition {
        await ProductAnalytics.shared.librarySyncReceipt(receipt)
    }
}

/// Synchronously owns the business receipt, then reuses ProductAnalytics'
/// durable queue and exact-id acknowledgement for transport. Server event-id
/// uniqueness is the final idempotency authority.
final class AnalyticsLibrarySyncReceiptOutbox: @unchecked Sendable {
    static let shared: AnalyticsLibrarySyncReceiptOutbox = {
        let key = ServiceRouting.current.isolatedStorageKey(
            "library_sync_receipts_v1"
        )
        return AnalyticsLibrarySyncReceiptOutbox(
            store: UserDefaultsAnalyticsLibrarySyncReceiptStore(key: key),
            reporter: ProductAnalyticsLibrarySyncReporter()
        )
    }()

    private let store: AnalyticsLibrarySyncReceiptStoring
    private let reporter: AnalyticsLibrarySyncReporting
    private let stateLock = NSLock()
    private var isDelivering = false
    private var replayRequestedWhileDelivering = false

    init(
        store: AnalyticsLibrarySyncReceiptStoring,
        reporter: AnalyticsLibrarySyncReporting
    ) {
        self.store = store
        self.reporter = reporter
    }

    /// `bindSessionId` is already a UUID and a sync completion is unique within
    /// that binding session, so reusing it as eventId gives deterministic retry
    /// semantics without storing a second generated identifier first.
    @discardableResult
    func persist(
        session: AnalyticsLibraryConnectionSession,
        bookCount: Int,
        occurredAt: Date
    ) -> Bool {
        guard bookCount > 0,
              Self.requiresDurableReceipt(session.source),
              UUID(uuidString: session.bindSessionId) != nil else { return false }
        let receipt = AnalyticsLibrarySyncReceiptV1(
            eventId: session.bindSessionId,
            bindSessionId: session.bindSessionId,
            source: session.source,
            entryPoint: session.entryPoint,
            startedAt: session.startedAt,
            occurredAt: occurredAt,
            bookCount: bookCount
        )
        do {
            _ = try store.persist(receipt)
            return true
        } catch {
#if DEBUG
            print("[Analytics] library sync receipt persist failed: \(error)")
#endif
            return false
        }
    }

    func start() {
        stateLock.lock()
        guard !isDelivering else {
            replayRequestedWhileDelivering = true
            stateLock.unlock()
            return
        }
        isDelivering = true
        stateLock.unlock()
        Task { [weak self] in await self?.deliverClaimedSnapshot() }
    }

    /// Internal for deterministic crash/relaunch and acknowledgement tests.
    func deliverPending() async {
        stateLock.lock()
        guard !isDelivering else {
            stateLock.unlock()
            return
        }
        isDelivering = true
        stateLock.unlock()
        await deliverClaimedSnapshot()
    }

    func pendingReceipts() -> [AnalyticsLibrarySyncReceiptV1] {
        (try? store.load()) ?? []
    }

    private func deliverClaimedSnapshot() async {
        let receipts = (try? store.load()) ?? []
        for receipt in receipts {
            let disposition = await reporter.recordLibrarySync(receipt)
            guard disposition == .accepted else { continue }
            // If this removal fails, the receipt intentionally survives and is
            // replayed. The collector's exact event-id ACK makes that harmless.
            try? store.remove(eventId: receipt.eventId)
        }

        stateLock.lock()
        isDelivering = false
        let shouldReplay = replayRequestedWhileDelivering
        replayRequestedWhileDelivering = false
        stateLock.unlock()
        if shouldReplay { start() }
    }

    static func requiresDurableReceipt(_ source: AnalyticsLibrarySource) -> Bool {
        switch source {
        case .kindle, .weread, .googleBooks, .kobo: return true
        case .oreilly: return false
        }
    }
}

/// Reusable, privacy-safe lifecycle recorder for every bound-library UI.
/// It deliberately owns no account, URL, title, or credential data.
final class AnalyticsLibraryConnectionRecorder: @unchecked Sendable {
    let session: AnalyticsLibraryConnectionSession

    private let lock = NSLock()
    private let syncReceiptOutbox: AnalyticsLibrarySyncReceiptOutbox
    private var entryTapAlreadyTracked: Bool
    private var terminalRecorded = false
    private var recordedKeys = Set<String>()

    init(
        session: AnalyticsLibraryConnectionSession,
        entryTapAlreadyTracked: Bool,
        syncReceiptOutbox: AnalyticsLibrarySyncReceiptOutbox = .shared
    ) {
        self.session = session
        self.entryTapAlreadyTracked = entryTapAlreadyTracked
        self.syncReceiptOutbox = syncReceiptOutbox
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

    @discardableResult
    func record(
        _ stage: AnalyticsLibraryConnectionStage,
        result: AnalyticsResult,
        errorCode: String? = nil,
        bookCount: Int? = nil,
        occurredAt: Date = Date()
    ) -> Bool {
        let key = "\(stage.rawValue):\(result.rawValue):\(errorCode ?? "-")"
        lock.lock()
        guard !terminalRecorded else {
            lock.unlock()
            return false
        }
        let requiresReceipt = stage == .syncCompleted
            && result == .success
            && AnalyticsLibrarySyncReceiptOutbox.requiresDurableReceipt(session.source)
        if requiresReceipt {
            guard let bookCount,
                  syncReceiptOutbox.persist(
                    session: session,
                    bookCount: bookCount,
                    occurredAt: occurredAt
                  ) else {
                lock.unlock()
                return false
            }
        }
        let inserted = recordedKeys.insert(key).inserted
        if inserted,
           stage == .syncCompleted || stage == .failed || stage == .cancelled {
            terminalRecorded = true
        }
        lock.unlock()
        guard inserted else { return false }
        let analyticsSession = session
        if requiresReceipt {
            // Receipt is already durable before terminal state or product UX.
            syncReceiptOutbox.start()
            Task { @MainActor in
                GrowthLoopConversionCoordinator.shared.libraryDidSync(
                    source: analyticsSession.source
                )
            }
            return true
        }
        Task { @MainActor in
            ProductAnalytics.shared.trackLibraryConnection(
                analyticsSession,
                stage: stage,
                result: result,
                errorCode: errorCode,
                bookCount: bookCount,
                occurredAt: occurredAt
            )
            if stage == .syncCompleted, result == .success {
                GrowthLoopConversionCoordinator.shared.libraryDidSync(
                    source: analyticsSession.source
                )
            }
        }
        return true
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
    let clientRegion: String
    /// 实际自有服务线路，与产品发行区域分开记录。可选是为了继续解码升级前
    /// 已落盘、尚未发送的队列事件；本版本新建的事件始终写入 global/cn。
    let serviceRoute: String?
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
        .appFirstOpen: .init(required: ["firstOpenKind"], optional: []),
        .onboardingStep: .init(
            required: ["step", "result", "source"],
            optional: [
                "durationMs", "errorCode", "bindSessionId", "configId", "storefront",
                "choiceSurface", "recommendationSignal", "matched",
            ]
        ),
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
        .paywallShown: .init(
            required: ["trigger", "entitlementState"],
            optional: [
                "hadMeaningfulReading", "valueMilestone", "offerEligible",
                "selectedProductId", "configId",
            ]
        ),
        .paywallAction: .init(
            required: ["trigger", "productId", "action"],
            optional: ["offerEligible", "trialDays"]
        ),
        .accountGateResult: .init(
            required: ["trigger", "productId", "result", "gatePresented"],
            optional: ["durationMs", "errorCode"]
        ),
        .homeProCardImpression: .init(required: [], optional: []),
        .homeProCardYearlyPurchaseTap: .init(required: [], optional: []),
        .homeProCardSecondaryTap: .init(required: [], optional: []),
        .purchaseStart: .init(
            required: ["store", "productId", "trigger"],
            optional: ["transactionEnvironment"]
        ),
        .purchaseResult: .init(
            required: ["store", "productId", "trigger", "result"],
            optional: ["errorCode", "transactionEnvironment", "offerType", "trialDays"]
        ),
        .entitlementActivated: .init(
            required: ["store", "productId", "trigger", "activationSource"],
            optional: ["syncState", "transactionEnvironment", "offerType", "trialDays"]
        ),
        .reviewPromptEligible: .init(required: ["trigger", "store"], optional: []),
        .reviewRequestAttempted: .init(required: ["trigger", "store", "result"], optional: ["errorCode"]),
        .reviewStoreLinkOpened: .init(required: ["trigger", "store"], optional: []),
        .adAttributionAttempt: .init(
            required: ["provider", "attemptCount", "outcome", "latencyMs"],
            optional: ["errorCode"]
        ),
        .adAttribution: .init(
            required: ["provider", "attributionResult"],
            optional: [
                "attributionToken", "attemptCount", "campaignSource", "campaignMedium",
                "landingTouchId", "campaignId", "adGroupId", "creativeId",
            ]
        ),
        .growthConfigAssigned: .init(
            required: ["configId", "market", "eligibility"],
            optional: []
        ),
        .paywallPlanSelected: .init(
            required: ["productId", "selectionSource", "interval"],
            optional: ["trigger", "configId", "offerEligible"]
        ),
        .resumeReminder: .init(
            required: ["action", "result"],
            optional: ["permissionStatus", "trigger", "daysSinceLastRead", "errorCode"]
        ),
    ]

    private static let forbidden = Set([
        "content", "text", "ocrText", "fileName", "title", "url", "urlPath",
        "referrer", "email", "imageData", "rawError", "responseBody",
        // 中国区新增的身份与支付凭据字段：手机号登录与支付宝订阅都不得进入埋点。
        "phone", "phoneNumber", "smsCode", "verificationCode",
        "wechatUid", "wereadUid", "agreementNo",
        "userId", "backendUserId", "transactionId", "originalTransactionId",
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

    static let youTubeEntries: Set<String> = ["share", "clipboard", "scheme", "paste", "sample"]

    // 客户端两端的失败面在 canonical 里统一登记：unsupported_webview 只有 Android 会发，
    // iOS 侧保留该值以便后端与看板共用同一套 reason 枚举。
    static let youTubeFailureReasons: Set<String> = [
        "no_captions",
        "live",
        "restricted",
        "unavailable",
        "caption_access",
        "player_bootstrap_failed",
        "youtube_access_limited",
        "unsupported_webview",
        "track_unavailable",
        "timeout",
        "unsupported_language",
    ]

    static let youTubeCaptionKinds: Set<String> = ["asr", "manual"]

    static let adAttributionDiagnosticCodes: Set<String> = [
        "simulator",
        "token_empty",
        "network_unavailable",
        "request_timed_out",
        "adservices_unavailable",
        "unsupported_platform",
        "unknown",
        "window_expired",
        "analytics_rejected",
        "analytics_unavailable",
        "service_unavailable",
        "service_disconnected",
        "feature_not_supported",
        "permission_error",
        "developer_error",
        "client_error",
        "distribution_not_play",
    ]

    static let attributionProviders: Set<String> = ["apple_ads", "play_install_referrer"]
    static let installCampaignSources: Set<String> = [
        "google_ads", "meta_ads", "tiktok_ads", "microsoft_ads", "organic", "unknown",
    ]
    static let installCampaignMediums: Set<String> = [
        "cpc", "paid_social", "display", "video", "affiliate", "organic", "unknown",
    ]
    static let storefrontChoiceSurfaces: Set<String> = ["inline", "chooser"]
    static let storefrontRecommendationSignals: Set<String> = [
        "persisted_onboarding", "bound_library", "local_signals", "default",
    ]

    static let paywallValueMilestones: Set<String> = [
        "library_ready",
        "first_audio",
        "listen_30s",
        "listen_300s",
        "quota_exhausted",
    ]

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
        if let trialDays = properties.trialDays,
           !(1...3_650).contains(trialDays) {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "trialDays",
                value: String(trialDays)
            )
        }
        if let offerType = properties.offerType,
           AnalyticsOfferType(rawValue: offerType) == nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "offerType",
                value: offerType
            )
        }

        if name == .appSessionStart {
            guard let launchType = properties.launchType,
                  AnalyticsLaunchType(rawValue: launchType) != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "launchType",
                    value: properties.launchType ?? "nil"
                )
            }
        }

        if name == .appFirstOpen {
            guard let firstOpenKind = properties.firstOpenKind,
                  AnalyticsFirstOpenKind(rawValue: firstOpenKind) != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "firstOpenKind",
                    value: properties.firstOpenKind ?? "nil"
                )
            }
            return
        }

        if name == .onboardingStep {
            try validateOnboardingStep(properties)
            return
        }

        if name == .adAttributionAttempt {
            try validateAdAttributionAttempt(properties)
            return
        }

        if name == .adAttribution {
            try validateAdAttribution(properties)
            return
        }

        if name == .growthConfigAssigned {
            guard let configId = properties.configId,
                  !configId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "configId",
                    value: properties.configId ?? "nil"
                )
            }
            guard let market = properties.market,
                  AnalyticsGrowthMarket(rawValue: market) != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "market",
                    value: properties.market ?? "nil"
                )
            }
            guard let eligibility = properties.eligibility,
                  AnalyticsGrowthEligibility(rawValue: eligibility) != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "eligibility",
                    value: properties.eligibility ?? "nil"
                )
            }
            return
        }

        if name == .paywallShown || name == .paywallPlanSelected {
            try validatePaywallEvent(name, properties: properties)
            return
        }

        if name == .paywallAction {
            try validatePaywallAction(properties)
            return
        }

        if name == .accountGateResult {
            try validateAccountGateResult(properties)
            return
        }

        if name == .resumeReminder {
            try validateResumeReminder(properties)
            return
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
        if name == .purchaseResult || name == .entitlementActivated {
            try validatePurchaseOffer(properties)
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

    private static func validateOnboardingStep(_ properties: AnalyticsProperties) throws {
        guard let step = properties.step,
              AnalyticsOnboardingStep(rawValue: step) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "step",
                value: properties.step ?? "nil"
            )
        }
        guard let result = properties.result,
              AnalyticsOnboardingOutcome(rawValue: result) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "result",
                value: properties.result ?? "nil"
            )
        }
        guard let source = properties.source,
              AnalyticsOnboardingSource(rawValue: source) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "source",
                value: properties.source ?? "nil"
            )
        }
        if let durationMs = properties.durationMs, durationMs < 0 {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "durationMs",
                value: String(durationMs)
            )
        }
        if let bindSessionId = properties.bindSessionId,
           UUID(uuidString: bindSessionId) == nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "bindSessionId",
                value: bindSessionId
            )
        }
        if result == AnalyticsOnboardingOutcome.failed.rawValue,
           properties.errorCode?.isEmpty != false {
            throw AnalyticsSchemaError.invalidPropertyValue(property: "errorCode", value: "nil")
        }
        if result != AnalyticsOnboardingOutcome.failed.rawValue,
           properties.errorCode != nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "errorCode",
                value: properties.errorCode ?? "nil"
            )
        }

        let hasStorefrontDecision = properties.storefront != nil
            || properties.choiceSurface != nil
            || properties.recommendationSignal != nil
            || properties.matched != nil
        if hasStorefrontDecision {
            guard step == AnalyticsOnboardingStep.storefront.rawValue else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "step",
                    value: step
                )
            }
            guard properties.storefront != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "storefront",
                    value: "nil"
                )
            }
            guard let surface = properties.choiceSurface,
                  storefrontChoiceSurfaces.contains(surface) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "choiceSurface",
                    value: properties.choiceSurface ?? "nil"
                )
            }
            guard let signal = properties.recommendationSignal,
                  storefrontRecommendationSignals.contains(signal) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "recommendationSignal",
                    value: properties.recommendationSignal ?? "nil"
                )
            }
            if properties.matched != nil,
               result != AnalyticsOnboardingOutcome.done.rawValue {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "matched",
                    value: String(properties.matched ?? false)
                )
            }
        }
    }

    private static func validateAdAttributionAttempt(
        _ properties: AnalyticsProperties
    ) throws {
        guard let provider = properties.provider,
              attributionProviders.contains(provider) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "provider",
                value: properties.provider ?? "nil"
            )
        }
        guard let attemptCount = properties.attemptCount, (1...8).contains(attemptCount) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "attemptCount",
                value: properties.attemptCount.map(String.init) ?? "nil"
            )
        }
        guard let latencyMs = properties.latencyMs, (0...120_000).contains(latencyMs) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "latencyMs",
                value: properties.latencyMs.map(String.init) ?? "nil"
            )
        }
        let validOutcomes: Set<String> = provider == "apple_ads"
            ? [
                AnalyticsAdAttributionAttemptOutcome.tokenAcquired.rawValue,
                AnalyticsAdAttributionAttemptOutcome.retryableError.rawValue,
                AnalyticsAdAttributionAttemptOutcome.unsupported.rawValue,
                AnalyticsAdAttributionAttemptOutcome.windowExpired.rawValue,
                AnalyticsAdAttributionAttemptOutcome.deliveryNotAccepted.rawValue,
            ]
            : [
                AnalyticsAdAttributionAttemptOutcome.referrerAcquired.rawValue,
                AnalyticsAdAttributionAttemptOutcome.retryableError.rawValue,
                AnalyticsAdAttributionAttemptOutcome.unsupported.rawValue,
                AnalyticsAdAttributionAttemptOutcome.failed.rawValue,
            ]
        guard let outcome = properties.outcome, validOutcomes.contains(outcome) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "outcome",
                value: properties.outcome ?? "nil"
            )
        }
        if let errorCode = properties.errorCode,
           !adAttributionDiagnosticCodes.contains(errorCode) {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "errorCode",
                value: errorCode
            )
        }
        let successOutcomes: Set<String> = [
            AnalyticsAdAttributionAttemptOutcome.tokenAcquired.rawValue,
            AnalyticsAdAttributionAttemptOutcome.referrerAcquired.rawValue,
        ]
        let requiresError = !successOutcomes.contains(outcome)
        if requiresError != (properties.errorCode != nil) {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "errorCode",
                value: properties.errorCode ?? "nil"
            )
        }
    }

    private static func validateAdAttribution(
        _ properties: AnalyticsProperties
    ) throws {
        guard let provider = properties.provider,
              attributionProviders.contains(provider) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "provider",
                value: properties.provider ?? "nil"
            )
        }
        if let attemptCount = properties.attemptCount,
           !(1...8).contains(attemptCount) {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "attemptCount",
                value: String(attemptCount)
            )
        }

        if provider == "apple_ads" {
            guard let result = properties.attributionResult,
                  ["token", "unavailable", "unsupported"].contains(result) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "attributionResult",
                    value: properties.attributionResult ?? "nil"
                )
            }
            let hasToken = properties.attributionToken?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            guard (result == "token") == hasToken else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "attributionToken",
                    value: properties.attributionToken ?? "nil"
                )
            }
            let campaignFields = [
                properties.campaignSource,
                properties.campaignMedium,
                properties.landingTouchId,
                properties.campaignId,
                properties.adGroupId,
                properties.creativeId,
            ]
            guard campaignFields.allSatisfy({ $0 == nil }) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "campaignSource",
                    value: properties.campaignSource ?? "unexpected_play_campaign_fields"
                )
            }
            return
        }

        let playResults: Set<String> = [
            "attributed", "organic", "unavailable", "unsupported", "failed",
        ]
        guard let result = properties.attributionResult,
              playResults.contains(result) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "attributionResult",
                value: properties.attributionResult ?? "nil"
            )
        }
        guard properties.attributionToken == nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "attributionToken",
                value: "play_token_forbidden"
            )
        }

        let attributed = result == "attributed"
        if attributed {
            guard let source = properties.campaignSource,
                  installCampaignSources.contains(source) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "campaignSource",
                    value: properties.campaignSource ?? "nil"
                )
            }
            guard let medium = properties.campaignMedium,
                  installCampaignMediums.contains(medium) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "campaignMedium",
                    value: properties.campaignMedium ?? "nil"
                )
            }
        } else if properties.campaignSource != nil || properties.campaignMedium != nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "campaignSource",
                value: properties.campaignSource ?? "unexpected_campaign_medium"
            )
        }

        if let landingTouchId = properties.landingTouchId {
            guard attributed,
                  landingTouchId.range(
                    of: "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                    options: .regularExpression
                  ) != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "landingTouchId",
                    value: landingTouchId
                )
            }
        }

        for (key, value) in [
            ("campaignId", properties.campaignId),
            ("adGroupId", properties.adGroupId),
            ("creativeId", properties.creativeId),
        ] where value != nil {
            let value = value ?? ""
            guard attributed,
                  value.range(
                    of: "^[0-9]{1,32}$",
                    options: .regularExpression
                  ) != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(property: key, value: value)
            }
        }
    }

    private static func validatePaywallEvent(
        _ name: AnalyticsEventName,
        properties: AnalyticsProperties
    ) throws {
        if let milestone = properties.valueMilestone,
           !paywallValueMilestones.contains(milestone) {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "valueMilestone",
                value: milestone
            )
        }
        if name == .paywallPlanSelected {
            guard let productId = properties.productId,
                  isSafeAnalyticsIdentifier(productId) else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "productId",
                    value: properties.productId ?? "nil"
                )
            }
            guard let source = properties.selectionSource,
                  AnalyticsPlanSelectionSource(rawValue: source) != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "selectionSource",
                    value: properties.selectionSource ?? "nil"
                )
            }
            guard let interval = properties.interval,
                  AnalyticsPlanInterval(rawValue: interval) != nil else {
                throw AnalyticsSchemaError.invalidPropertyValue(
                    property: "interval",
                    value: properties.interval ?? "nil"
                )
            }
        }
    }

    private static func validatePaywallAction(
        _ properties: AnalyticsProperties
    ) throws {
        guard let productId = properties.productId,
              isSafeAnalyticsIdentifier(productId) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "productId",
                value: properties.productId ?? "nil"
            )
        }
        guard let action = properties.action,
              AnalyticsPaywallAction(rawValue: action) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "action",
                value: properties.action ?? "nil"
            )
        }
        if properties.trialDays != nil, properties.offerEligible != true {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "trialDays",
                value: properties.trialDays.map(String.init) ?? "nil"
            )
        }
    }

    private static func validateAccountGateResult(
        _ properties: AnalyticsProperties
    ) throws {
        guard let productId = properties.productId,
              isSafeAnalyticsIdentifier(productId) else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "productId",
                value: properties.productId ?? "nil"
            )
        }
        guard let result = properties.result,
              AnalyticsAccountGateResult(rawValue: result) != nil else {
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
        let safeError = properties.errorCode.map(isSafeAnalyticsIdentifier) ?? false
        if result == "success", properties.errorCode != nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "errorCode",
                value: properties.errorCode ?? "nil"
            )
        }
        if result != "success", !safeError {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "errorCode",
                value: properties.errorCode ?? "nil"
            )
        }
    }

    private static func validatePurchaseOffer(
        _ properties: AnalyticsProperties
    ) throws {
        if properties.trialDays != nil,
           properties.offerType != AnalyticsOfferType.introductory.rawValue {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "trialDays",
                value: properties.trialDays.map(String.init) ?? "nil"
            )
        }
    }

    private static func isSafeAnalyticsIdentifier(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$",
            options: .regularExpression
        ) != nil
    }

    private static func validateResumeReminder(_ properties: AnalyticsProperties) throws {
        guard let action = properties.action,
              AnalyticsResumeReminderAction(rawValue: action) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "action",
                value: properties.action ?? "nil"
            )
        }
        guard let result = properties.result,
              AnalyticsResumeReminderOutcome(rawValue: result) != nil else {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "result",
                value: properties.result ?? "nil"
            )
        }
        if let status = properties.permissionStatus,
           AnalyticsNotificationPermissionStatus(rawValue: status) == nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "permissionStatus",
                value: status
            )
        }
        if let days = properties.daysSinceLastRead, days < 0 || days > 365 {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "daysSinceLastRead",
                value: String(days)
            )
        }
        if result == AnalyticsResumeReminderOutcome.failed.rawValue,
           properties.errorCode?.isEmpty != false {
            throw AnalyticsSchemaError.invalidPropertyValue(property: "errorCode", value: "nil")
        }
        if result != AnalyticsResumeReminderOutcome.failed.rawValue,
           properties.errorCode != nil {
            throw AnalyticsSchemaError.invalidPropertyValue(
                property: "errorCode",
                value: properties.errorCode ?? "nil"
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
                  youTubeEntries.contains(entry) else {
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
                  youTubeFailureReasons.contains(reason) else {
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
            guard let kind = properties.kind, youTubeCaptionKinds.contains(kind) else {
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
    /// 发行区域（`AppRegion`）。区分中国大陆版与全球版的同一事件。
    let region: String
    /// 本次进程冻结的自有服务线路，值域为 global/cn。
    let serviceRoute: String
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
            clientRegion: client.region,
            serviceRoute: client.serviceRoute,
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

enum AnalyticsDeliveryDisposition: Equatable, Sendable {
    case accepted
    case rejected(reason: String)
    case transportUnavailable
    case invalidEvent
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
    var session: URLSession = OwnedAPIURLSession.shared

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
    private var deliveryWaiters: [
        String: [CheckedContinuation<AnalyticsDeliveryDisposition, Never>]
    ] = [:]
    /// Process-local delivery receipts close a narrow race where a fire-and-
    /// forget enqueue reaches the actor after an acknowledgement waiter has
    /// already delivered the same id. Server idempotency remains authoritative
    /// across launches; this bounded cache prevents an avoidable duplicate in
    /// the current process.
    private var resolvedDeliveries: [String: AnalyticsDeliveryDisposition] = [:]
    private var resolvedDeliveryOrder: [String] = []
    private let maxResolvedDeliveries = 256

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
        guard resolvedDeliveries[event.eventId] == nil else { return }
        if !queue.contains(where: { $0.eventId == event.eventId }) {
            queue.append(event)
            if queue.count > maxQueueSize {
                let removed = queue.prefix(queue.count - maxQueueSize).map(\.eventId)
                queue.removeFirst(queue.count - maxQueueSize)
                for eventId in removed {
                    resolveWaiters(for: eventId, with: .transportUnavailable)
                }
            }
            store.save(queue)
        }
        if queue.count >= batchSize { await flush() }
    }

    /// Enqueue an idempotent event and wait until the collector explicitly
    /// accepts or rejects that exact event id. A transport failure leaves the
    /// event in the durable queue but wakes the caller as unavailable, so
    /// lifecycle code can retry without falsely sealing local state.
    func enqueueAndAwaitAcknowledgement(
        _ event: AnalyticsEventEnvelope
    ) async -> AnalyticsDeliveryDisposition {
        if let disposition = resolvedDeliveries[event.eventId] {
            return disposition
        }
        if let rejected = deadLetters.last(where: { $0.eventId == event.eventId }) {
            return .rejected(reason: rejected.reason)
        }
        if !queue.contains(where: { $0.eventId == event.eventId }) {
            queue.append(event)
            if queue.count > maxQueueSize {
                let removed = queue.prefix(queue.count - maxQueueSize).map(\.eventId)
                queue.removeFirst(queue.count - maxQueueSize)
                for eventId in removed {
                    resolveWaiters(for: eventId, with: .transportUnavailable)
                }
            }
            store.save(queue)
        }
        return await withCheckedContinuation { continuation in
            deliveryWaiters[event.eventId, default: []].append(continuation)
            Task { await self.flush() }
        }
    }

    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !queue.isEmpty {
            let batch = Array(queue.prefix(batchSize))
            do {
                let result = try await transport.send(batch)
                let batchEventIds = Set(batch.map(\.eventId))
                let resolved = result.acceptedEventIds
                    .union(result.rejectedEventIds)
                    .intersection(batchEventIds)
                guard !resolved.isEmpty else {
                    resolveAllWaiters(with: .transportUnavailable)
                    return
                }
                if !result.rejectedEventIds.isEmpty {
                    retainRejectedEvents(
                        batch,
                        rejectedEventIds: result.rejectedEventIds,
                        reasons: result.rejectionReasons
                    )
                }
                queue.removeAll { resolved.contains($0.eventId) }
                store.save(queue)
                for eventId in result.acceptedEventIds where resolved.contains(eventId) {
                    rememberResolved(.accepted, for: eventId)
                    resolveWaiters(for: eventId, with: .accepted)
                }
                for eventId in result.rejectedEventIds where resolved.contains(eventId) {
                    let disposition = AnalyticsDeliveryDisposition.rejected(
                        reason: result.rejectionReasons[eventId] ?? "server_rejected"
                    )
                    rememberResolved(disposition, for: eventId)
                    resolveWaiters(
                        for: eventId,
                        with: disposition
                    )
                }
            } catch {
                #if DEBUG
                print("⚠️ [Analytics] flush retained \(queue.count) events: \(error.localizedDescription)")
                #endif
                resolveAllWaiters(with: .transportUnavailable)
                return
            }
        }
    }

    func queuedEvents() -> [AnalyticsEventEnvelope] { queue }
    func rejectedEvents() -> [AnalyticsDeadLetterRecord] { deadLetters }

    private func resolveWaiters(
        for eventId: String,
        with disposition: AnalyticsDeliveryDisposition
    ) {
        let continuations = deliveryWaiters.removeValue(forKey: eventId) ?? []
        continuations.forEach { $0.resume(returning: disposition) }
    }

    private func resolveAllWaiters(with disposition: AnalyticsDeliveryDisposition) {
        let pending = deliveryWaiters
        deliveryWaiters.removeAll()
        for continuations in pending.values {
            continuations.forEach { $0.resume(returning: disposition) }
        }
    }

    private func rememberResolved(
        _ disposition: AnalyticsDeliveryDisposition,
        for eventId: String
    ) {
        if resolvedDeliveries[eventId] == nil {
            resolvedDeliveryOrder.append(eventId)
        }
        resolvedDeliveries[eventId] = disposition
        if resolvedDeliveryOrder.count > maxResolvedDeliveries {
            let overflow = resolvedDeliveryOrder.count - maxResolvedDeliveries
            for staleId in resolvedDeliveryOrder.prefix(overflow) {
                resolvedDeliveries.removeValue(forKey: staleId)
            }
            resolvedDeliveryOrder.removeFirst(overflow)
        }
    }

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

enum AppFirstOpenAcknowledgementState: String, Codable, Equatable, Sendable {
    case pending
    case acknowledged
}

/// Durable install anchor for the first-party growth funnel.
///
/// `occurredAt`, `eventId`, and `firstOpenKind` are frozen before the current
/// instrumentation writes any application defaults. A failed delivery can
/// therefore be retried on a later launch without moving the install clock or
/// minting another logical first-open event.
struct AppFirstOpenPersistentStateV1: Codable, Equatable, Sendable {
    let eventId: String
    let firstOpenKind: AnalyticsFirstOpenKind
    let occurredAt: Date
    var ackState: AppFirstOpenAcknowledgementState
    var acknowledgedAt: Date?

    var isAcknowledged: Bool {
        ackState == .acknowledged && acknowledgedAt != nil
    }
}

protocol AppFirstOpenStateStoring: Sendable {
    func load() -> AppFirstOpenPersistentStateV1?
    func save(_ state: AppFirstOpenPersistentStateV1)
}

struct UserDefaultsAppFirstOpenStateStore: AppFirstOpenStateStoring, @unchecked Sendable {
    static let defaultKey = "app_first_open.state.v1"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AppFirstOpenPersistentStateV1? {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(
                  AppFirstOpenPersistentStateV1.self,
                  from: data
              ),
              UUID(uuidString: state.eventId) != nil else {
            return nil
        }
        return state
    }

    func save(_ state: AppFirstOpenPersistentStateV1) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

protocol AppFirstOpenReporting: Sendable {
    func recordFirstOpen(
        kind: AnalyticsFirstOpenKind,
        eventId: String,
        occurredAt: Date
    ) async -> AnalyticsDeliveryDisposition
}

struct ProductAnalyticsAppFirstOpenReporter: AppFirstOpenReporting {
    func recordFirstOpen(
        kind: AnalyticsFirstOpenKind,
        eventId: String,
        occurredAt: Date
    ) async -> AnalyticsDeliveryDisposition {
        await ProductAnalytics.shared.appFirstOpen(
            kind: kind,
            eventId: eventId,
            occurredAt: occurredAt
        )
    }
}

/// Owns the exactly-once client side of `app_first_open` delivery. The server's
/// event-id uniqueness remains the final authority; locally we seal only an
/// explicit collector acknowledgement and otherwise retry the same envelope.
@MainActor
final class AppFirstOpenService {
    static let shared = AppFirstOpenService()

    typealias Clock = @Sendable () -> Date

    private let stateStore: AppFirstOpenStateStoring
    private let reporter: AppFirstOpenReporting
    private let now: Clock
    private var deliveryTask: Task<Void, Never>?

    init(
        stateStore: AppFirstOpenStateStoring = UserDefaultsAppFirstOpenStateStore(),
        reporter: AppFirstOpenReporting = ProductAnalyticsAppFirstOpenReporter(),
        now: @escaping Clock = { Date() }
    ) {
        self.stateStore = stateStore
        self.reporter = reporter
        self.now = now
    }

    /// Must be the first statement in the app initializer. Looking at the
    /// application's persistent domain before writing this state distinguishes
    /// a clean container from an already-used container receiving the new
    /// instrumentation. Unknown/corrupt prior state is conservatively backfill.
    @discardableResult
    static func prepareInitialState(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsAppFirstOpenStateStore.defaultKey,
        applicationDomainName: String? = Bundle.main.bundleIdentifier,
        now: Date = Date(),
        eventId: String = UUID().uuidString
    ) -> AppFirstOpenPersistentStateV1 {
        let store = UserDefaultsAppFirstOpenStateStore(defaults: defaults, key: key)
        if let existing = store.load() { return existing }

        let hadExistingApplicationState: Bool
        if let applicationDomainName {
            let domain = defaults.persistentDomain(forName: applicationDomainName)
            hadExistingApplicationState = domain?.keys.contains { $0 != key } == true
                || defaults.object(forKey: key) != nil
        } else {
            // A production app always has a bundle id. If it is unexpectedly
            // unavailable, never inflate new-install counts.
            hadExistingApplicationState = true
        }

        let state = AppFirstOpenPersistentStateV1(
            eventId: UUID(uuidString: eventId)?.uuidString ?? UUID().uuidString,
            firstOpenKind: hadExistingApplicationState
                ? .instrumentationBackfill
                : .freshInstall,
            occurredAt: now,
            ackState: .pending,
            acknowledgedAt: nil
        )
        store.save(state)
        return state
    }

    func start() {
        guard deliveryTask == nil,
              let state = stateStore.load(),
              !state.isAcknowledged else { return }
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            await self.deliverPreparedState()
            self.deliveryTask = nil
        }
    }

    /// Internal so deterministic tests can exercise restart/retry semantics
    /// without sleeping or driving UIApplication lifecycle notifications.
    func deliverPreparedState() async {
        guard var state = stateStore.load(), !state.isAcknowledged else { return }
        let disposition = await reporter.recordFirstOpen(
            kind: state.firstOpenKind,
            eventId: state.eventId,
            occurredAt: state.occurredAt
        )
        guard disposition == .accepted else { return }
        state.ackState = .acknowledged
        state.acknowledgedAt = now()
        stateStore.save(state)
    }
}

@MainActor
final class ProductAnalytics {
    static let shared = ProductAnalytics()

    private static let anonymousIdKey = "product_analytics_anonymous_id_v1"
    private static let growthAssignmentKey = "growth_config_assignment_analytics_v1"
    private let pipeline: AnalyticsPipeline
    private let client: AnalyticsClientInfo
    private(set) var appSessionId = UUID().uuidString
    private var appSessionStarted = false
    private var appSessionStartEnvelope: AnalyticsEventEnvelope?
    private var appSessionEnqueueTask: Task<Void, Never>?
    private var backgroundAt: Date?
    private var meaningfulReadReached = false
    private var scheduledFlushTask: Task<Void, Never>?

    private init() {
        // endpoint 来自启动时已冻结的 ServiceRouting；后续切换只影响下次进程，
        // 因而队列、transport 与其他业务请求不会混线。
        let endpoint = URL(string: Constants.API.analyticsEvents)
            ?? URL(string: "https://api.castreader.ai/api/events")!
        let queueKey = ServiceRouting.current.isolatedStorageKey("product_analytics_queue_v1")
        let deadLetterKey = ServiceRouting.current.isolatedStorageKey(
            "product_analytics_dead_letters_v1"
        )
        let pipeline = AnalyticsPipeline(
            store: UserDefaultsAnalyticsQueueStore(key: queueKey),
            transport: URLSessionAnalyticsTransport(endpoint: endpoint),
            deadLetterStore: UserDefaultsAnalyticsDeadLetterStore(key: deadLetterKey)
        )
        self.pipeline = pipeline
        self.client = AnalyticsClientInfo(
            environment: Self.environment,
            platform: "ios",
            variant: Self.clientVariant,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            anonymousId: Self.analyticsAnonymousId(),
            region: AppRegion.current.rawValue,
            serviceRoute: ServiceRouting.current.rawValue
        )
    }

    func startAppSession(launchType: String = "cold") {
        guard !appSessionStarted else { return }
        appSessionStarted = true
        do {
            let event = try AnalyticsEnvelopeFactory.make(
                name: .appSessionStart,
                context: .init(productArea: .app, surface: "app", entryPoint: nil),
                properties: .init(launchType: launchType),
                client: client,
                appSessionId: appSessionId,
                backendUserId: AuthService.shared.proUserId
            )
            appSessionStartEnvelope = event
            appSessionEnqueueTask = Task { [pipeline] in
                await pipeline.enqueue(event)
            }
            scheduleFlush()
        } catch {
#if DEBUG
            print("[Analytics] dropped invalid app session: \(error.localizedDescription)")
#endif
        }
    }

    /// Growth assignment depends on the collector having observed this
    /// anonymous install/session. Awaiting the exact event id removes the
    /// startup race between the normal two-second batch flush and status/v2.
    /// Other product paths remain fail-open; callers decide how to degrade when
    /// the collector is unavailable.
    func ensureCurrentAppSessionDelivered() async -> AnalyticsDeliveryDisposition {
        startAppSession()
        guard let event = appSessionStartEnvelope else { return .invalidEvent }
        scheduledFlushTask?.cancel()
        await appSessionEnqueueTask?.value
        return await pipeline.enqueueAndAwaitAcknowledgement(event)
    }

    /// Privacy-safe install identifier used by first-party growth identity
    /// linking. It is intentionally not an account id and contains no profile
    /// or content data.
    var privacySafeAnonymousId: String { client.anonymousId }

    /// The install anchor is immediate/acknowledged rather than ordinary
    /// fire-and-forget analytics. Its durable caller reuses the same id and
    /// occurred-at timestamp until the collector accepts it.
    func appFirstOpen(
        kind: AnalyticsFirstOpenKind,
        eventId: String,
        occurredAt: Date
    ) async -> AnalyticsDeliveryDisposition {
        startAppSession()
        await appSessionEnqueueTask?.value
        return await trackAndAwaitAcknowledgement(
            .appFirstOpen,
            context: .init(productArea: .app, surface: "app", entryPoint: nil),
            properties: .init(firstOpenKind: kind.rawValue),
            eventId: eventId,
            occurredAt: occurredAt
        )
    }

    func adAttributionAttempt(
        attemptCount: Int,
        outcome: AnalyticsAdAttributionAttemptOutcome,
        latencyMs: Int,
        errorCode: String?
    ) {
        track(
            .adAttributionAttempt,
            context: .init(productArea: .app, surface: "attribution", entryPoint: nil),
            properties: .init(
                latencyMs: latencyMs,
                errorCode: errorCode,
                provider: "apple_ads",
                attemptCount: attemptCount,
                outcome: outcome.rawValue
            )
        )
    }

    /// The terminal Apple Ads fact bypasses the ordinary delayed flush. The
    /// caller may seal its durable state only after this returns `.accepted`.
    func adAttribution(
        result: String,
        token: String?,
        attemptCount: Int,
        eventId: String
    ) async -> AnalyticsDeliveryDisposition {
        await trackAndAwaitAcknowledgement(
            .adAttribution,
            context: .init(productArea: .app, surface: "attribution", entryPoint: nil),
            properties: .init(
                provider: "apple_ads",
                attributionResult: result,
                attributionToken: token,
                attemptCount: attemptCount
            ),
            eventId: eventId
        )
    }

    @discardableResult
    func trackGrowthConfigAssigned(
        configId: String,
        market: String,
        eligibility: String
    ) -> String? {
        let signature = "\(configId)|\(market)|\(eligibility)"
        let defaultsKey = ServiceRouting.current.isolatedStorageKey(Self.growthAssignmentKey)
        guard UserDefaults.standard.string(forKey: defaultsKey) != signature else { return nil }
        let eventId = track(
            .growthConfigAssigned,
            context: .init(productArea: .app, surface: "growth_config", entryPoint: nil),
            properties: .init(
                configId: configId,
                market: market,
                eligibility: eligibility
            )
        )
        if eventId != nil { UserDefaults.standard.set(signature, forKey: defaultsKey) }
        return eventId
    }

    @discardableResult
    func trackPaywallPlanSelected(
        productId: String,
        selectionSource: AnalyticsPlanSelectionSource,
        interval: AnalyticsPlanInterval,
        trigger: String? = nil,
        configId: String? = nil,
        offerEligible: Bool? = nil
    ) -> String? {
        track(
            .paywallPlanSelected,
            context: .init(productArea: .billing, surface: "paywall", entryPoint: trigger),
            properties: .init(
                trigger: trigger,
                productId: productId,
                configId: configId,
                offerEligible: offerEligible,
                selectionSource: selectionSource.rawValue,
                interval: interval.rawValue
            )
        )
    }

    @discardableResult
    func trackPaywallAction(
        productId: String,
        action: AnalyticsPaywallAction,
        trigger: String,
        surface: String = "paywall",
        offerEligible: Bool? = nil,
        trialDays: Int? = nil,
        purchaseAttemptId: String? = nil
    ) -> String? {
        track(
            .paywallAction,
            context: .init(
                productArea: .billing,
                surface: surface,
                entryPoint: trigger,
                purchaseAttemptId: purchaseAttemptId
            ),
            properties: .init(
                trigger: trigger,
                productId: productId,
                offerEligible: offerEligible,
                action: action.rawValue,
                trialDays: offerEligible == true ? trialDays : nil
            )
        )
    }

    @discardableResult
    func trackAccountGateResult(
        productId: String,
        result: AnalyticsAccountGateResult,
        gatePresented: Bool,
        trigger: String,
        surface: String = "paywall",
        durationMs: Int,
        errorCode: String? = nil,
        purchaseAttemptId: String? = nil
    ) -> String? {
        track(
            .accountGateResult,
            context: .init(
                productArea: .billing,
                surface: surface,
                entryPoint: trigger,
                purchaseAttemptId: purchaseAttemptId
            ),
            properties: .init(
                durationMs: max(0, durationMs),
                result: result.rawValue,
                errorCode: result == .success ? nil : errorCode,
                trigger: trigger,
                productId: productId,
                gatePresented: gatePresented
            )
        )
    }

    @discardableResult
    func trackResumeReminder(
        action: AnalyticsResumeReminderAction,
        result: AnalyticsResumeReminderOutcome,
        permissionStatus: AnalyticsNotificationPermissionStatus? = nil,
        trigger: String? = nil,
        daysSinceLastRead: Int? = nil,
        errorCode: String? = nil
    ) -> String? {
        track(
            .resumeReminder,
            context: .init(productArea: .app, surface: "resume_reminder", entryPoint: trigger),
            properties: .init(
                result: result.rawValue,
                errorCode: errorCode,
                trigger: trigger,
                action: action.rawValue,
                permissionStatus: permissionStatus?.rawValue,
                daysSinceLastRead: daysSinceLastRead
            )
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
            appSessionStartEnvelope = nil
            appSessionEnqueueTask = nil
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

    /// Delivers a previously persisted non-empty shelf receipt and returns only
    /// the collector's disposition for that exact bind-scoped event id.
    func librarySyncReceipt(
        _ receipt: AnalyticsLibrarySyncReceiptV1
    ) async -> AnalyticsDeliveryDisposition {
        await trackAndAwaitAcknowledgement(
            .libraryConnection,
            context: .init(
                productArea: .reader,
                surface: "library_connection",
                entryPoint: receipt.entryPoint
            ),
            properties: .init(
                source: receipt.source.rawValue,
                bindSessionId: receipt.bindSessionId,
                stage: AnalyticsLibraryConnectionStage.syncCompleted.rawValue,
                durationMs: max(
                    0,
                    Int(receipt.occurredAt.timeIntervalSince(receipt.startedAt) * 1_000)
                ),
                result: AnalyticsResult.success.rawValue,
                bookCountBucket: Self.bookCountBucket(receipt.bookCount)
            ),
            eventId: receipt.eventId,
            occurredAt: receipt.occurredAt
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

    private func trackAndAwaitAcknowledgement(
        _ name: AnalyticsEventName,
        context: AnalyticsEventContext,
        properties: AnalyticsProperties,
        eventId: String,
        occurredAt: Date = Date()
    ) async -> AnalyticsDeliveryDisposition {
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
            scheduledFlushTask?.cancel()
            return await pipeline.enqueueAndAwaitAcknowledgement(event)
        } catch {
#if DEBUG
            print("[Analytics] dropped invalid immediate event \(name.rawValue): \(error.localizedDescription)")
#endif
            return .invalidEvent
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
