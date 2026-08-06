//
//  AppReviewPromptManager.swift
//  CastReader
//
//  Engagement-gated, locally persisted App Store review request policy.
//

import Combine
import Foundation

enum AppReviewTrigger: String, Codable, Sendable {
    case firstReadCompleted = "first_read_completed"
    case libraryConnected = "library_connected"
    case thirdFiveMinuteRead = "third_five_minute_read"
    case settings
}

extension Notification.Name {
    static let castReaderLibraryConnectedForReview = Notification.Name(
        "castreader.review.libraryConnected"
    )
}

struct AppReviewAttempt: Codable, Equatable, Sendable {
    let version: String
    let attemptedAt: Date
}

/// In-memory engagement progress for one user-initiated reading session.
/// Kindle may replace its page-local ReadAloudViewModel during an automatic
/// visual page turn, so this value is explicitly handed to the next owner.
struct AppReviewReadSessionProgress: Equatable, Sendable {
    let sessionID: String
    private(set) var playbackSeconds: Double
    private(set) var didRecordFiveMinuteMilestone: Bool

    init(
        sessionID: String = UUID().uuidString,
        playbackSeconds: Double = 0,
        didRecordFiveMinuteMilestone: Bool = false
    ) {
        self.sessionID = sessionID
        self.playbackSeconds = playbackSeconds.isFinite ? max(0, playbackSeconds) : 0
        self.didRecordFiveMinuteMilestone = didRecordFiveMinuteMilestone
    }

    /// Returns true exactly once, when this logical reading session first
    /// reaches its true-playback threshold.
    mutating func record(
        rawPlaybackDelta: Double,
        policy: AppReviewPromptPolicy = .production,
        milestoneSeconds: Double = 300
    ) -> Bool {
        guard !didRecordFiveMinuteMilestone,
              milestoneSeconds.isFinite,
              milestoneSeconds > 0 else { return false }
        playbackSeconds += policy.acceptedPlaybackDelta(rawPlaybackDelta)
        guard playbackSeconds >= milestoneSeconds else { return false }
        didRecordFiveMinuteMilestone = true
        return true
    }
}

/// One-shot custody for a logical read session while a paged reader confirms
/// its next surface. The token is consumed only by an automatic page commit;
/// a manual/failed/last-page path discards it and cannot revive it later.
struct AppReviewAutomaticPageContinuation: Equatable, Sendable {
    private(set) var pendingProgress: AppReviewReadSessionProgress?

    static func candidate(
        _ progress: AppReviewReadSessionProgress,
        for sourceKind: ReadingSourceKind
    ) -> AppReviewReadSessionProgress? {
        switch sourceKind {
        case .kindle, .weread, .googleBooks, .kobo, .oreilly:
            return progress
        case .photo, .text, .web, .docx, .pdf, .epub:
            return nil
        }
    }

    mutating func arm(_ progress: AppReviewReadSessionProgress) {
        pendingProgress = progress
    }

    mutating func takeForConfirmedAutomaticCommit(
        _ isConfirmedAutomaticCommit: Bool
    ) -> AppReviewReadSessionProgress? {
        defer { pendingProgress = nil }
        guard isConfirmedAutomaticCommit else { return nil }
        return pendingProgress
    }

    mutating func cancel() {
        pendingProgress = nil
    }

    static func progressForConfirmedCommit(
        queuedProgress: AppReviewReadSessionProgress?,
        activeProgress: AppReviewReadSessionProgress?,
        isConfirmedAutomaticCommit: Bool,
        fallbackWillResetActiveProgress: Bool
    ) -> AppReviewReadSessionProgress? {
        guard isConfirmedAutomaticCommit else { return nil }
        if let queuedProgress { return queuedProgress }
        guard fallbackWillResetActiveProgress else { return nil }
        return activeProgress
    }
}

/// Pure presentation gate shared by MainTab and unit tests. StoreKit must only
/// be called after every transient activity has stayed clear for the debounce
/// window; in particular, an empty streaming queue is not the same as stopped.
struct AppReviewPresentationGate: Equatable, Sendable {
    let pending: Bool
    let appIsActive: Bool
    let isHome: Bool
    let playbackIsQuiescent: Bool
    let readerIsHidden: Bool
    let kindleReaderIsHidden: Bool
    let importChromeIsVisible: Bool
    let homeIsIdle: Bool
    let clipboardSheetIsHidden: Bool
    let shareInboxIsHidden: Bool
    let voiceCloneSheetIsHidden: Bool
    let voicePanelIsHidden: Bool
    let onboardingIsHidden: Bool

    var canStabilize: Bool {
        pending
            && appIsActive
            && isHome
            && playbackIsQuiescent
            && readerIsHidden
            && kindleReaderIsHidden
            && importChromeIsVisible
            && homeIsIdle
            && clipboardSheetIsHidden
            && shareInboxIsHidden
            && voiceCloneSheetIsHidden
            && voicePanelIsHidden
            && onboardingIsHidden
    }

    static func playbackIsQuiescent(
        isPlaying: Bool,
        isBuffering: Bool,
        moreSegmentsExpected: Bool,
        isWaitingForNextSegment: Bool
    ) -> Bool {
        !isPlaying
            && !isBuffering
            && !moreSegmentsExpected
            && !isWaitingForNextSegment
    }
}

struct AppReviewPromptState: Codable, Equatable, Sendable {
    var firstRecordedAt: Date?
    var activeDayIdentifiers: [String]
    var fiveMinuteReadSessionIDs: [String]
    var pendingTrigger: AppReviewTrigger?
    var attempts: [AppReviewAttempt]
    var lastAttemptedVersion: String?

    init(
        firstRecordedAt: Date? = nil,
        activeDayIdentifiers: [String] = [],
        fiveMinuteReadSessionIDs: [String] = [],
        pendingTrigger: AppReviewTrigger? = nil,
        attempts: [AppReviewAttempt] = [],
        lastAttemptedVersion: String? = nil
    ) {
        self.firstRecordedAt = firstRecordedAt
        self.activeDayIdentifiers = activeDayIdentifiers
        self.fiveMinuteReadSessionIDs = fiveMinuteReadSessionIDs
        self.pendingTrigger = pendingTrigger
        self.attempts = attempts
        self.lastAttemptedVersion = lastAttemptedVersion
    }
}

struct AppReviewPromptPolicy: Sendable {
    static let production = AppReviewPromptPolicy()

    let minimumAge: TimeInterval
    let minimumActiveDays: Int
    let minimumFiveMinuteReadSessions: Int
    let attemptCooldown: TimeInterval
    let rollingWindow: TimeInterval
    let maximumAttemptsPerRollingWindow: Int

    init(
        minimumAge: TimeInterval = 72 * 60 * 60,
        minimumActiveDays: Int = 2,
        minimumFiveMinuteReadSessions: Int = 3,
        attemptCooldown: TimeInterval = 90 * 24 * 60 * 60,
        rollingWindow: TimeInterval = 365 * 24 * 60 * 60,
        maximumAttemptsPerRollingWindow: Int = 3
    ) {
        self.minimumAge = minimumAge
        self.minimumActiveDays = minimumActiveDays
        self.minimumFiveMinuteReadSessions = minimumFiveMinuteReadSessions
        self.attemptCooldown = attemptCooldown
        self.rollingWindow = rollingWindow
        self.maximumAttemptsPerRollingWindow = maximumAttemptsPerRollingWindow
    }

    func acceptedPlaybackDelta(_ rawDelta: Double) -> Double {
        guard rawDelta.isFinite, rawDelta > 0, rawDelta <= 2.01 else { return 0 }
        return rawDelta
    }

    @discardableResult
    func recordActiveDay(
        in state: inout AppReviewPromptState,
        at date: Date,
        calendar: Calendar
    ) -> Bool {
        var changed = false
        if state.firstRecordedAt == nil {
            state.firstRecordedAt = date
            changed = true
        }

        let identifier = Self.dayIdentifier(for: date, calendar: calendar)
        if state.activeDayIdentifiers.count < minimumActiveDays,
           !state.activeDayIdentifiers.contains(identifier) {
            state.activeDayIdentifiers.append(identifier)
            changed = true
        }
        changed = compact(&state, at: date) || changed
        return changed
    }

    /// Records one distinct read session that accumulated 300 seconds from
    /// positive, non-seek playback ticks. Eligibility only creates `pending`;
    /// presenting StoreKit is owned by the main UI once it is safe.
    @discardableResult
    func recordFiveMinuteReadSession(
        in state: inout AppReviewPromptState,
        sessionID: String,
        at date: Date,
        version: String,
        calendar: Calendar
    ) -> Bool {
        _ = recordActiveDay(in: &state, at: date, calendar: calendar)
        if !sessionID.isEmpty,
           state.fiveMinuteReadSessionIDs.count < minimumFiveMinuteReadSessions,
           !state.fiveMinuteReadSessionIDs.contains(sessionID) {
            state.fiveMinuteReadSessionIDs.append(sessionID)
        }

        _ = compact(&state, at: date)
        return evaluatePending(in: &state, at: date, version: version)
    }

    /// A first, observable success is a better review moment than an arbitrary
    /// age/session threshold. It becomes pending immediately, while the main UI
    /// still owns the safety gate that waits until readers and sheets are gone.
    @discardableResult
    func recordPositiveOutcome(
        in state: inout AppReviewPromptState,
        trigger: AppReviewTrigger,
        at date: Date,
        version: String,
        calendar: Calendar
    ) -> Bool {
        guard trigger == .firstReadCompleted || trigger == .libraryConnected else {
            return false
        }
        _ = recordActiveDay(in: &state, at: date, calendar: calendar)
        _ = compact(&state, at: date)
        guard state.pendingTrigger == nil,
              frequencyAllowsAttempt(state, at: date, version: version) else {
            return false
        }
        state.pendingTrigger = trigger
        return true
    }

    /// Re-evaluates after an active-day/time boundary as well as after a read.
    /// This lets three early qualifying sessions become pending once the 72-hour
    /// gate matures, without requiring an artificial fourth five-minute read.
    @discardableResult
    func evaluatePending(
        in state: inout AppReviewPromptState,
        at date: Date,
        version: String
    ) -> Bool {
        guard state.pendingTrigger == nil,
              engagementThresholdReached(state, at: date),
              frequencyAllowsAttempt(state, at: date, version: version) else {
            return false
        }
        state.pendingTrigger = .thirdFiveMinuteRead
        return true
    }

    func engagementThresholdReached(
        _ state: AppReviewPromptState,
        at date: Date
    ) -> Bool {
        guard let firstRecordedAt = state.firstRecordedAt,
              date.timeIntervalSince(firstRecordedAt) >= minimumAge else {
            return false
        }
        return Set(state.activeDayIdentifiers).count >= minimumActiveDays
            && Set(state.fiveMinuteReadSessionIDs).count >= minimumFiveMinuteReadSessions
    }

    func frequencyAllowsAttempt(
        _ state: AppReviewPromptState,
        at date: Date,
        version: String
    ) -> Bool {
        guard !version.isEmpty,
              state.lastAttemptedVersion != version,
              !state.attempts.contains(where: { $0.version == version }) else {
            return false
        }

        if let latestAttempt = state.attempts.map(\.attemptedAt).max(),
           date.timeIntervalSince(latestAttempt) < attemptCooldown {
            return false
        }

        let rollingAttempts = state.attempts.filter {
            let age = date.timeIntervalSince($0.attemptedAt)
            return age >= 0 && age < rollingWindow
        }
        return rollingAttempts.count < maximumAttemptsPerRollingWindow
    }

    /// Consumes pending immediately before invoking StoreKit. This is the
    /// frequency-counting moment; Apple's API does not reveal whether it later
    /// displays a sheet or whether the user submits a rating.
    func consumePendingAttempt(
        in state: inout AppReviewPromptState,
        at date: Date,
        version: String
    ) -> AppReviewTrigger? {
        guard let trigger = state.pendingTrigger,
              frequencyAllowsAttempt(state, at: date, version: version) else {
            return nil
        }
        state.pendingTrigger = nil
        state.lastAttemptedVersion = version
        state.attempts.append(AppReviewAttempt(version: version, attemptedAt: date))
        _ = compact(&state, at: date)
        return trigger
    }

    @discardableResult
    private func compact(
        _ state: inout AppReviewPromptState,
        at date: Date
    ) -> Bool {
        let originalActiveDays = state.activeDayIdentifiers
        let originalSessions = state.fiveMinuteReadSessionIDs
        let originalAttempts = state.attempts

        var seenActiveDays = Set<String>()
        state.activeDayIdentifiers = Array(state.activeDayIdentifiers.filter {
            seenActiveDays.insert($0).inserted
        }.prefix(minimumActiveDays))
        var seenSessions = Set<String>()
        state.fiveMinuteReadSessionIDs = Array(state.fiveMinuteReadSessionIDs.filter {
            seenSessions.insert($0).inserted
        }.prefix(minimumFiveMinuteReadSessions))
        state.attempts = Array(state.attempts
            .filter {
                let age = date.timeIntervalSince($0.attemptedAt)
                return age < rollingWindow
            }
            .sorted { $0.attemptedAt < $1.attemptedAt }
            .suffix(maximumAttemptsPerRollingWindow))

        return state.activeDayIdentifiers != originalActiveDays
            || state.fiveMinuteReadSessionIDs != originalSessions
            || state.attempts != originalAttempts
    }

    private static func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

@MainActor
final class AppReviewPromptManager: ObservableObject {
    static let shared = AppReviewPromptManager()
    static let appStoreReviewURL = URL(
        string: "https://apps.apple.com/app/id6757636395?action=write-review"
    )!

    @Published private(set) var pendingTrigger: AppReviewTrigger?

    private let defaults: UserDefaults
    private let storageKey: String
    private let policy: AppReviewPromptPolicy
    private let calendar: Calendar
    private let now: () -> Date
    private let version: () -> String
    private let analyticsRecorder: (AnalyticsEventName, AnalyticsEventContext, AnalyticsProperties) -> Void
    private var state: AppReviewPromptState

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "app_review_prompt_state_v1",
        policy: AppReviewPromptPolicy = .production,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = { Date() },
        version: @escaping () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        },
        analyticsRecorder: ((
            AnalyticsEventName,
            AnalyticsEventContext,
            AnalyticsProperties
        ) -> Void)? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.policy = policy
        self.calendar = calendar
        self.now = now
        self.version = version
        if let data = defaults.data(forKey: storageKey),
           let restored = try? JSONDecoder().decode(AppReviewPromptState.self, from: data) {
            state = restored
        } else {
            state = AppReviewPromptState()
        }
        pendingTrigger = state.pendingTrigger
        self.analyticsRecorder = analyticsRecorder ?? { name, context, properties in
            _ = ProductAnalytics.shared.track(
                name,
                context: context,
                properties: properties
            )
        }
    }

    var isPending: Bool { pendingTrigger != nil }

    var snapshot: AppReviewPromptState { state }

    func recordActiveDay() {
        let date = now()
        let changed = policy.recordActiveDay(in: &state, at: date, calendar: calendar)
        let becameEligible = policy.evaluatePending(
            in: &state,
            at: date,
            version: version()
        )
        pendingTrigger = state.pendingTrigger
        if changed || becameEligible { persist() }
        if becameEligible { recordEligibleEvent() }
    }

    func recordFiveMinuteReadSession(sessionID: String) {
        let date = now()
        let becameEligible = policy.recordFiveMinuteReadSession(
            in: &state,
            sessionID: sessionID,
            at: date,
            version: version(),
            calendar: calendar
        )
        pendingTrigger = state.pendingTrigger
        persist()

        if becameEligible { recordEligibleEvent() }
    }

    func recordPositiveOutcome(_ trigger: AppReviewTrigger) {
        let date = now()
        let becameEligible = policy.recordPositiveOutcome(
            in: &state,
            trigger: trigger,
            at: date,
            version: version(),
            calendar: calendar
        )
        pendingTrigger = state.pendingTrigger
        persist()

        if becameEligible { recordEligibleEvent(trigger: trigger) }
    }

    private func recordEligibleEvent(
        trigger: AppReviewTrigger = .thirdFiveMinuteRead
    ) {
        analyticsRecorder(
            .reviewPromptEligible,
            AnalyticsEventContext(
                productArea: .app,
                surface: "review_prompt",
                entryPoint: nil
            ),
            AnalyticsProperties(
                trigger: trigger.rawValue,
                store: "app_store"
            )
        )
    }

    /// Invokes the system request only after atomically consuming and
    /// persisting the attempt. A `success` event means only that the
    /// nonthrowing StoreKit API was called; it never means shown or submitted.
    @discardableResult
    func performSystemReviewRequest(_ request: () -> Void) -> Bool {
        let date = now()
        guard let trigger = policy.consumePendingAttempt(
            in: &state,
            at: date,
            version: version()
        ) else {
            return false
        }
        pendingTrigger = nil
        persist()
        request()
        analyticsRecorder(
            .reviewRequestAttempted,
            AnalyticsEventContext(
                productArea: .app,
                surface: "review_prompt",
                entryPoint: nil
            ),
            AnalyticsProperties(
                result: AnalyticsResult.success.rawValue,
                trigger: trigger.rawValue,
                store: "app_store"
            )
        )
        return true
    }

    func recordSettingsStoreLinkOpened() {
        analyticsRecorder(
            .reviewStoreLinkOpened,
            AnalyticsEventContext(
                productArea: .app,
                surface: "settings",
                entryPoint: "settings"
            ),
            AnalyticsProperties(
                trigger: AppReviewTrigger.settings.rawValue,
                store: "app_store"
            )
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
