// Release-only compatibility surface for code paths guarded by
// `Constants.Features.cloudStorageEnabled == false`.
//
// The provider adapters, SDKs, OAuth configuration, assets and localization
// catalog are intentionally not members of the App Store target.

import Foundation
import SwiftUI

struct ImportSession: Identifiable, Equatable, Sendable {
    let id = UUID()
}

@MainActor
final class CloudStorageCenter: ObservableObject {
    static let shared = CloudStorageCenter()

    func state(for provider: CloudProviderID) -> CloudConnectionState { .disconnected }
    func isConfigured(_ provider: CloudProviderID) -> Bool { false }
    func refreshConnectionStates() async {}

    func disconnect(_ provider: CloudProviderID) async -> CloudDisconnectResult {
        CloudDisconnectResult(
            provider: provider,
            remoteRevocationStatus: .unsupported
        )
    }

    func retryPendingRemoteRevocation(
        for provider: CloudProviderID
    ) async -> CloudDisconnectResult {
        await disconnect(provider)
    }
}

enum CloudHistoryReopenProgress: Equatable, Sendable {
    case validatingAccount
    case downloading(CloudDownloadProgress)
    case importing(DocumentImportProgress)
}

typealias CloudHistoryReopenProgressHandler = @Sendable (CloudHistoryReopenProgress) -> Void

struct CloudHistoryReopenService: Sendable {
    func reopen(
        _ record: HistoryRecord,
        mode: ReaderMode,
        scenario: ExplainContentType? = nil,
        analyticsContext: AnalyticsContentContext? = nil,
        progress: @escaping CloudHistoryReopenProgressHandler = { _ in }
    ) async throws -> DocumentImportResult {
        throw CancellationError()
    }
}

struct CloudHistoryFailurePresentation: Identifiable {
    enum Recovery: Equatable {
        case reconnect(forceAccountSelection: Bool)
        case removeRecord
        case retry
        case dismiss
    }

    let id = UUID()
    let record: HistoryRecord
    let message: String
    let recovery: Recovery

    static func make(record: HistoryRecord, error: Error) -> Self? { nil }
    static func contentChanged(record: HistoryRecord, result: DocumentImportResult) -> Bool { false }
}

struct CloudStorageFlowView: View {
    init(
        provider: CloudProviderID,
        scenario: ExplainContentType?,
        mode: ReaderMode,
        analyticsContext: AnalyticsContentContext?,
        forceAccountSelection: Bool = false,
        showsDisclosureOnStart: Bool = false,
        privacyReviewOnly: Bool = false,
        expectedAccount: CloudAccount? = nil,
        onComplete: @escaping (DocumentImportResult) -> Void,
        onCancel: @escaping () -> Void
    ) {}

    var body: some View { EmptyView() }
}

struct CloudStorageProviderRow: View {
    let provider: CloudProviderID
    let state: CloudConnectionState
    let isConfigured: Bool
    let onOpen: () -> Void
    let onSwitchAccount: () -> Void
    let onDisconnect: () -> Void
    let onShowPrivacy: () -> Void

    var body: some View { EmptyView() }
}

struct CloudProviderIcon: View {
    let provider: CloudProviderID
    var size: CGFloat = 42

    var body: some View { EmptyView() }
}
