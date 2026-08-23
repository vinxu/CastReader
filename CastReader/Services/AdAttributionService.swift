//
//  AdAttributionService.swift
//  CastReader
//
//  Reliable Apple Ads attribution delivery. The AdServices token is fetched
//  off the main thread, retried at stable foreground offsets, and considered
//  complete only after the first-party analytics collector acknowledges the
//  terminal event id.
//

import Foundation
import AdServices

enum AdAttributionProviderError: Error, Equatable, Sendable {
    case unsupportedPlatform
}

enum AdAttributionDiagnosticCode: String, Codable, CaseIterable, Sendable {
    case simulator
    case tokenEmpty = "token_empty"
    case networkUnavailable = "network_unavailable"
    case requestTimedOut = "request_timed_out"
    case adServicesUnavailable = "adservices_unavailable"
    case unsupportedPlatform = "unsupported_platform"
    case unknown
    case windowExpired = "window_expired"
    case analyticsRejected = "analytics_rejected"
    case analyticsUnavailable = "analytics_unavailable"
}

enum AdAttributionTerminalResult: String, Codable, Sendable {
    case token
    case unavailable
    case unsupported
}

struct AdAttributionRetryPolicy: Equatable, Sendable {
    /// Offsets from each foreground activation, not cumulative sleep lengths.
    let foregroundOffsets: [TimeInterval]
    let tokenWindow: TimeInterval
    /// Shared mobile analytics contract bounds attemptCount at eight. This
    /// still permits a complete four-offset sequence plus one foreground
    /// resume without creating an event the collector must reject.
    let maxAttempts: Int

    init(
        foregroundOffsets: [TimeInterval],
        tokenWindow: TimeInterval,
        maxAttempts: Int = 8
    ) {
        self.foregroundOffsets = foregroundOffsets
        self.tokenWindow = tokenWindow
        self.maxAttempts = max(1, maxAttempts)
    }

    static let production = AdAttributionRetryPolicy(
        foregroundOffsets: [0, 2, 10, 60],
        tokenWindow: 24 * 60 * 60,
        maxAttempts: 8
    )
}

struct AdAttributionPersistentStateV2: Codable, Equatable, Sendable {
    var firstAttemptAt: Date?
    var attemptCount: Int = 0
    var terminalEventId: String?
    var terminalResult: AdAttributionTerminalResult?
    var terminalToken: String?
    var acknowledgedAt: Date?

    var isAcknowledged: Bool { acknowledgedAt != nil }
}

protocol AdAttributionStateStoring: Sendable {
    func load() -> AdAttributionPersistentStateV2
    func save(_ state: AdAttributionPersistentStateV2)
}

struct UserDefaultsAdAttributionStateStore: AdAttributionStateStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = ServiceRouting.current.isolatedStorageKey("ad_attribution.state.v2")
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AdAttributionPersistentStateV2 {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(
                  AdAttributionPersistentStateV2.self,
                  from: data
              ) else {
            return AdAttributionPersistentStateV2()
        }
        return state
    }

    func save(_ state: AdAttributionPersistentStateV2) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }
}

protocol AdAttributionTokenProviding: Sendable {
    func attributionToken() async throws -> String
}

struct SystemAdAttributionTokenProvider: AdAttributionTokenProviding {
    func attributionToken() async throws -> String {
        #if targetEnvironment(simulator)
        throw AdAttributionProviderError.unsupportedPlatform
        #else
        // AAAttribution is synchronous and may touch a system service. Keep it
        // off the launch/foreground MainActor path.
        return try await Task.detached(priority: .utility) {
            try AAAttribution.attributionToken()
        }.value
        #endif
    }
}

protocol AdAttributionReporting: Sendable {
    func recordAttempt(
        attemptCount: Int,
        outcome: AnalyticsAdAttributionAttemptOutcome,
        latencyMs: Int,
        errorCode: AdAttributionDiagnosticCode?
    ) async

    func recordTerminal(
        result: AdAttributionTerminalResult,
        token: String?,
        attemptCount: Int,
        eventId: String
    ) async -> AnalyticsDeliveryDisposition
}

struct ProductAnalyticsAdAttributionReporter: AdAttributionReporting {
    func recordAttempt(
        attemptCount: Int,
        outcome: AnalyticsAdAttributionAttemptOutcome,
        latencyMs: Int,
        errorCode: AdAttributionDiagnosticCode?
    ) async {
        await ProductAnalytics.shared.adAttributionAttempt(
            attemptCount: attemptCount,
            outcome: outcome,
            latencyMs: latencyMs,
            errorCode: errorCode?.rawValue
        )
    }

    func recordTerminal(
        result: AdAttributionTerminalResult,
        token: String?,
        attemptCount: Int,
        eventId: String
    ) async -> AnalyticsDeliveryDisposition {
        await ProductAnalytics.shared.adAttribution(
            result: result.rawValue,
            token: token,
            attemptCount: attemptCount,
            eventId: eventId
        )
    }
}

/// Lifecycle-owned coordinator. Scheduling is MainActor-isolated, while the
/// injected token provider performs the blocking system call on a utility task.
@MainActor
final class AdAttributionService {
    static let shared = AdAttributionService()

    typealias Clock = @Sendable () -> Date
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let stateStore: AdAttributionStateStoring
    private let tokenProvider: AdAttributionTokenProviding
    private let reporter: AdAttributionReporting
    private let policy: AdAttributionRetryPolicy
    private let now: Clock
    private let sleep: Sleeper
    private var foregroundTask: Task<Void, Never>?

    init(
        stateStore: AdAttributionStateStoring = UserDefaultsAdAttributionStateStore(),
        tokenProvider: AdAttributionTokenProviding = SystemAdAttributionTokenProvider(),
        reporter: AdAttributionReporting = ProductAnalyticsAdAttributionReporter(),
        policy: AdAttributionRetryPolicy = .production,
        now: @escaping Clock = { Date() },
        sleep: @escaping Sleeper = { seconds in
            guard seconds > 0 else { return }
            try await Task.sleep(
                nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000)
            )
        }
    ) {
        self.stateStore = stateStore
        self.tokenProvider = tokenProvider
        self.reporter = reporter
        self.policy = policy
        self.now = now
        self.sleep = sleep
    }

    /// Cold-start entry point. Kept separate from the lifecycle name so startup
    /// wiring reads clearly and an immediate didBecomeActive notification is
    /// harmlessly deduplicated.
    func start() {
        didBecomeActive()
    }

    /// Compatibility alias for older callers during the v1 -> v2 rollout.
    func reportOnceIfNeeded() {
        start()
    }

    func didBecomeActive() {
        guard foregroundTask == nil else { return }
        foregroundTask = Task { [weak self] in
            guard let self else { return }
            await self.runForegroundSequence()
            self.foregroundTask = nil
        }
    }

    func didEnterBackground() {
        foregroundTask?.cancel()
        foregroundTask = nil
    }

    /// Internal for deterministic unit tests; production calls it only through
    /// lifecycle scheduling above.
    func runForegroundSequence() async {
        var state = stateStore.load()
        guard !state.isAcknowledged else { return }

        if state.terminalEventId != nil {
            _ = await deliverPendingTerminal(&state)
            return
        }

        let activationAt = now()
        if hasExpired(state, at: activationAt) {
            await expireWindow(&state)
            return
        }

        for offset in policy.foregroundOffsets {
            guard state.attemptCount < policy.maxAttempts else { return }
            let wait = max(0, activationAt.addingTimeInterval(offset).timeIntervalSince(now()))
            do {
                try await sleep(wait)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            if hasExpired(state, at: now()) {
                await expireWindow(&state)
                return
            }
            let shouldStop = await attemptToken(&state)
            if shouldStop { return }
        }
    }

    private func attemptToken(_ state: inout AdAttributionPersistentStateV2) async -> Bool {
        let startedAt = now()
        if state.firstAttemptAt == nil { state.firstAttemptAt = startedAt }
        state.attemptCount += 1
        stateStore.save(state)
        let attemptCount = state.attemptCount

        do {
            let token = try await tokenProvider.attributionToken()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled else { return true }
            let latency = Self.latencyMilliseconds(from: startedAt, to: now())
            guard !token.isEmpty else {
                await reporter.recordAttempt(
                    attemptCount: attemptCount,
                    outcome: .retryableError,
                    latencyMs: latency,
                    errorCode: .tokenEmpty
                )
                return false
            }
            await reporter.recordAttempt(
                attemptCount: attemptCount,
                outcome: .tokenAcquired,
                latencyMs: latency,
                errorCode: nil
            )
            state.terminalEventId = UUID().uuidString
            state.terminalResult = .token
            state.terminalToken = token
            stateStore.save(state)
            _ = await deliverPendingTerminal(&state)
            return true
        } catch {
            guard !Task.isCancelled else { return true }
            let code = Self.diagnosticCode(for: error)
            let unsupported = code == .simulator || code == .unsupportedPlatform
            await reporter.recordAttempt(
                attemptCount: attemptCount,
                outcome: unsupported ? .unsupported : .retryableError,
                latencyMs: Self.latencyMilliseconds(from: startedAt, to: now()),
                errorCode: code
            )
            if unsupported {
                state.terminalEventId = UUID().uuidString
                state.terminalResult = .unsupported
                state.terminalToken = nil
                stateStore.save(state)
                _ = await deliverPendingTerminal(&state)
                return true
            }
            return false
        }
    }

    private func expireWindow(_ state: inout AdAttributionPersistentStateV2) async {
        let attemptCount = max(1, state.attemptCount)
        await reporter.recordAttempt(
            attemptCount: attemptCount,
            outcome: .windowExpired,
            latencyMs: 0,
            errorCode: .windowExpired
        )
        state.terminalEventId = UUID().uuidString
        state.terminalResult = .unavailable
        state.terminalToken = nil
        stateStore.save(state)
        _ = await deliverPendingTerminal(&state)
    }

    @discardableResult
    private func deliverPendingTerminal(
        _ state: inout AdAttributionPersistentStateV2
    ) async -> Bool {
        guard let eventId = state.terminalEventId,
              let result = state.terminalResult else { return false }
        if result == .token, state.terminalToken?.isEmpty != false {
            // Corrupt/incomplete pending state is not a deliverable terminal
            // fact. Re-enter token acquisition while the 24-hour window lives.
            state.terminalEventId = nil
            state.terminalResult = nil
            state.terminalToken = nil
            stateStore.save(state)
            return false
        }
        let disposition = await reporter.recordTerminal(
            result: result,
            token: state.terminalToken,
            attemptCount: max(1, state.attemptCount),
            eventId: eventId
        )
        switch disposition {
        case .accepted:
            state.acknowledgedAt = now()
            // The event id remains as the idempotency/audit key. The raw token
            // is no longer needed locally once the collector accepted it.
            state.terminalToken = nil
            stateStore.save(state)
            return true
        case .rejected:
            await recordDeliveryFailure(state, code: .analyticsRejected)
        case .transportUnavailable, .invalidEvent:
            await recordDeliveryFailure(state, code: .analyticsUnavailable)
        }
        return false
    }

    private func recordDeliveryFailure(
        _ state: AdAttributionPersistentStateV2,
        code: AdAttributionDiagnosticCode
    ) async {
        await reporter.recordAttempt(
            attemptCount: max(1, state.attemptCount),
            outcome: .deliveryNotAccepted,
            latencyMs: 0,
            errorCode: code
        )
    }

    private func hasExpired(_ state: AdAttributionPersistentStateV2, at date: Date) -> Bool {
        guard let firstAttemptAt = state.firstAttemptAt else { return false }
        return date.timeIntervalSince(firstAttemptAt) >= policy.tokenWindow
    }

    nonisolated static func latencyMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

    nonisolated static func diagnosticCode(for error: Error) -> AdAttributionDiagnosticCode {
        if let providerError = error as? AdAttributionProviderError,
           providerError == .unsupportedPlatform {
            #if targetEnvironment(simulator)
            return .simulator
            #else
            return .unsupportedPlatform
            #endif
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .requestTimedOut
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                return .networkUnavailable
            default:
                return .unknown
            }
        }
        let providerDomain = nsError.domain.lowercased()
        if providerDomain.contains("adservices")
            || providerDomain.contains("aattribution") {
            return .adServicesUnavailable
        }
        return .unknown
    }
}
