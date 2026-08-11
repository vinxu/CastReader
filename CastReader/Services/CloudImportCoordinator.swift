//
//  CloudImportCoordinator.swift
//  CastReader
//
//  Owns the single active import session. Session ID + monotonic epoch make
//  late OAuth, download and parse callbacks harmless after cancel/replacement.
//

import Foundation

struct ImportSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let epoch: UInt64
    let providerRawValue: String?

    /// Stored as raw values because ReaderMode and ExplainContentType predate
    /// Swift concurrency and do not yet declare Sendable in their source files.
    let scenarioRawValue: String?
    let modeRawValue: String
    let analyticsContext: AnalyticsContentContext?
    let startedAt: Date

    var scenario: ExplainContentType? {
        scenarioRawValue.flatMap(ExplainContentType.init(rawValue:))
    }

    var mode: ReaderMode {
        ReaderMode(rawValue: modeRawValue) ?? .read
    }

    init(
        id: UUID = UUID(),
        epoch: UInt64,
        provider: CloudProviderID? = nil,
        scenario: ExplainContentType?,
        mode: ReaderMode,
        analyticsContext: AnalyticsContentContext? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.epoch = epoch
        providerRawValue = provider?.rawValue
        scenarioRawValue = scenario?.rawValue
        modeRawValue = mode.rawValue
        self.analyticsContext = analyticsContext
        self.startedAt = startedAt
    }

    /// Raw initializer keeps fake/session tests independent from UI enum cases.
    init(
        id: UUID = UUID(),
        epoch: UInt64,
        providerRawValue: String? = nil,
        scenarioRawValue: String?,
        modeRawValue: String,
        analyticsContext: AnalyticsContentContext? = nil,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.epoch = epoch
        self.providerRawValue = providerRawValue
        self.scenarioRawValue = scenarioRawValue
        self.modeRawValue = modeRawValue
        self.analyticsContext = analyticsContext
        self.startedAt = startedAt
    }
}

enum CloudImportCoordinationError: Error, Equatable, Sendable {
    case staleSession
    case cancelled
}

actor CloudImportCoordinator {
    static let shared = CloudImportCoordinator()

    private struct ActiveOperation: Sendable {
        let id: UUID
        let cancel: @Sendable () -> Void
    }

    private struct SessionIdentity: Hashable, Sendable {
        let id: UUID
        let epoch: UInt64
    }

    private var epoch: UInt64 = 0
    private var current: ImportSession?
    private var activeOperation: ActiveOperation?
    private var explicitlyCancelledSessions: Set<SessionIdentity> = []

    @discardableResult
    func begin(
        provider: CloudProviderID? = nil,
        scenario: ExplainContentType?,
        mode: ReaderMode,
        analyticsContext: AnalyticsContentContext? = nil,
        startedAt: Date = Date()
    ) -> ImportSession {
        activeOperation?.cancel()
        activeOperation = nil
        epoch &+= 1
        let session = ImportSession(
            epoch: epoch,
            provider: provider,
            scenario: scenario,
            mode: mode,
            analyticsContext: analyticsContext,
            startedAt: startedAt
        )
        current = session
        return session
    }

    func currentSession() -> ImportSession? {
        current
    }

    func isCurrent(_ session: ImportSession) -> Bool {
        current?.id == session.id && current?.epoch == session.epoch
    }

    func requireCurrent(_ session: ImportSession) throws {
        guard isCurrent(session) else {
            throw CloudImportCoordinationError.staleSession
        }
    }

    /// Runs at most one cancellable operation for the active session. Beginning
    /// another session or cancelling the current one cancels the task. Even if
    /// an SDK ignores cancellation and returns later, the final epoch check
    /// prevents its value from being committed.
    func run<Value: Sendable>(
        for session: ImportSession,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try requireCurrent(session)

        activeOperation?.cancel()
        let operationID = UUID()
        let task = Task { try await operation() }
        activeOperation = ActiveOperation(id: operationID, cancel: { task.cancel() })

        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            clearOperation(id: operationID)
            try requireCurrent(session)
            return value
        } catch {
            clearOperation(id: operationID)
            let identity = SessionIdentity(id: session.id, epoch: session.epoch)
            if explicitlyCancelledSessions.remove(identity) != nil {
                throw CloudImportCoordinationError.cancelled
            }
            guard isCurrent(session) else {
                throw CloudImportCoordinationError.staleSession
            }
            if error is CancellationError || Task.isCancelled {
                invalidate(session)
                throw CloudImportCoordinationError.cancelled
            }
            throw error
        }
    }

    /// Filters provider progress through the same session/epoch gate. The sink
    /// decides how to hop to MainActor for UI state.
    nonisolated func progressHandler(
        for session: ImportSession,
        sink: @escaping CloudDownloadProgressHandler
    ) -> CloudDownloadProgressHandler {
        { [weak self] progress in
            guard let self else { return }
            Task { await self.deliver(progress, for: session, sink: sink) }
        }
    }

    @discardableResult
    func finish(_ session: ImportSession) -> Bool {
        guard isCurrent(session) else { return false }
        activeOperation?.cancel()
        activeOperation = nil
        current = nil
        return true
    }

    @discardableResult
    func cancel(_ session: ImportSession? = nil) -> Bool {
        if let session, !isCurrent(session) { return false }
        guard let activeSession = current else { return false }
        if activeOperation != nil {
            explicitlyCancelledSessions.insert(
                SessionIdentity(id: activeSession.id, epoch: activeSession.epoch)
            )
        }
        activeOperation?.cancel()
        activeOperation = nil
        current = nil
        epoch &+= 1
        return true
    }

    @discardableResult
    func cancel(provider: CloudProviderID) -> Bool {
        guard current?.providerRawValue == provider.rawValue else { return false }
        return cancel(current)
    }

    private func invalidate(_ session: ImportSession) {
        guard isCurrent(session) else { return }
        activeOperation = nil
        current = nil
        epoch &+= 1
    }

    private func clearOperation(id: UUID) {
        guard activeOperation?.id == id else { return }
        activeOperation = nil
    }

    private func deliver(
        _ progress: CloudDownloadProgress,
        for session: ImportSession,
        sink: CloudDownloadProgressHandler
    ) {
        guard isCurrent(session) else { return }
        sink(progress)
    }
}
