import Foundation

enum ContentResumeError: LocalizedError {
    case unavailableItem, missingResource, changedAccount, unsupportedMode, completedItem
    var errorDescription: String? {
        switch self {
        case .unavailableItem: AppLocalized("此内容已移除或暂不可用，原操作不会打开其他内容。")
        case .missingResource: AppLocalized("进度已保留，请重新导入原文件")
        case .changedAccount: AppLocalized("账号已切换，请在当前账号重新打开内容。")
        case .completedItem: AppLocalized("此内容已标记完成，请在文库中打开。")
        case .unsupportedMode: AppLocalized("此入口暂不支持该模式，请打开内容后选择。")
        }
    }
}

struct ContentResumeResult {
    let itemID: String
    let contentChanged: Bool
}

/// Routes a stable catalog identity, never a position copied into a card or
/// notification. Format/provider adapters retain their verified locator logic.
@MainActor
final class ResumeCoordinator {
    private unowned let player: PlayerCoordinator
    private let history: HistoryStore
    private var requestID: UUID?

    init(player: PlayerCoordinator, history: HistoryStore) {
        self.player = player
        self.history = history
    }

    func open(itemID: String?, mode: ReaderMode = .read, autoplay: Bool = false,
              entryPoint: String,
              progress: @escaping (CloudHistoryReopenProgress) -> Void = { _ in }) async throws -> ContentResumeResult {
        let started = Date()
        let request = UUID()
        requestID = request
        let playerGeneration = player.presentationGeneration
        guard let boundary = history.progressBoundaryToken else { throw ContentResumeError.changedAccount }
        let catalog = ContentCatalog(history: history)
        let selected = itemID.flatMap { catalog.item(id: $0) } ?? (itemID == nil ? catalog.continuing.first : nil)
        guard let selected else { throw ContentResumeError.unavailableItem }
        let id = selected.id
        if autoplay && selected.state == .completed { throw ContentResumeError.completedItem }
        func validate() throws {
            try Task.checkCancellation()
            guard requestID == request, player.presentationGeneration == playerGeneration else { throw CancellationError() }
            guard history.progressBoundaryToken == boundary else { throw ContentResumeError.changedAccount }
            guard history.visibleRecords.contains(where: { $0.id == id }) else { throw ContentResumeError.unavailableItem }
        }
        try validate()
        let record = selected.record
        if record.sourceKind == .kindle {
            let book = KindleLibraryStore.shared.boundBooks.first { $0.id == id } ?? history.kindleBook(for: record)
            guard let book else { throw ContentResumeError.missingResource }
            guard mode == .read else { throw ContentResumeError.unsupportedMode }
            player.close()
            KindlePlaybackCenter.shared.open(book: book,
                intent: autoplay ? .autoplayRead(requestID: request) : .present)
            ReaderRunLog.write("CATALOG resume dispatched source=kindle autoplay=\(autoplay)")
            return ContentResumeResult(itemID: id, contentChanged: false)
        }
        if record.sourceKind == .youtube {
            guard mode == .read else { throw ContentResumeError.unsupportedMode }
            guard let url = record.sourceURL,
                  YouTubeRouteCenter.shared.open(url, entry: .history, autoplay: autoplay) else {
                throw ContentResumeError.missingResource
            }
            return ContentResumeResult(itemID: id, contentChanged: false)
        }
        let context = ProductAnalytics.shared.beginContentIntent(source: .history,
            format: AnalyticsContentFormat(record.sourceKind), entryPoint: entryPoint,
            intendedMode: mode == .read ? "read" : "explain")
        var changed = false
        let document: ReadingDocument
        if record.requiresRemoteReopen {
            guard Constants.Features.cloudStorageEnabled else { throw ContentResumeError.unavailableItem }
            let result = try await CloudHistoryReopenService().reopen(record, mode: mode,
                analyticsContext: context, progress: progress)
            try validate()
            document = result.document
            changed = CloudHistoryFailurePresentation.contentChanged(record: record, result: result)
        } else if record.sourceKind == .photo, let instant = history.instantPhotoDocument(record) {
            document = instant
        } else {
            guard let reopened = try await history.reopen(record) else { throw ContentResumeError.missingResource }
            try validate()
            document = reopened
        }
        try validate()
        let needsOCR = record.sourceKind == .photo && document.paragraphs.isEmpty
        player.open(document, mode: mode, autoplay: autoplay && !needsOCR, analyticsContext: context,
                    reusingLocalPayload: !record.requiresRemoteReopen && LocalDocumentCache.supports(record.sourceKind))
        if LocalDocumentCache.supports(record.sourceKind) {
            ReaderRunLog.write("LOCAL resume presented source=\(record.sourceKindRaw) seconds=\(Date().timeIntervalSince(started))")
        }
        let instanceID = player.session?.instanceID
        if needsOCR {
            // Preserve the request/account ownership through deferred Vision.
            Task { @MainActor [weak self] in
                guard let self, let recognized = await self.history.recognizePhoto(record),
                      self.requestID == request, self.history.progressBoundaryToken == boundary,
                      self.player.session?.instanceID == instanceID,
                      self.history.visibleRecords.contains(where: { $0.id == id }) else { return }
                self.player.upgradeSessionContent(recognized)
                if autoplay, self.player.session?.document.id == id {
                    if mode == .read { self.player.session?.readVM.ensurePlaying() }
                    else { self.player.session?.explainVM.start() }
                }
            }
        }
        ReaderRunLog.write("CATALOG resume dispatched source=\(record.sourceKind.rawValue) autoplay=\(autoplay)")
        return ContentResumeResult(itemID: id, contentChanged: changed)
    }
}
