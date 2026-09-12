import Foundation
import UIKit

struct KindleOfflineCapturedPage {
    let position: KindleOfflineSourcePosition
    let document: ReadingDocument
}

@MainActor
protocol KindleOfflineBookSource: AnyObject {
    var offlineSourceBook: KindleBook { get }
    func beginOfflineBookCapture(restoring interruptedPosition: KindleOfflineSourcePosition?) async throws -> KindleOfflineSourcePosition
    func captureOfflineBookPage(after: KindleOfflineSourcePosition?) async throws -> KindleOfflineCapturedPage
    func endOfflineBookCapture() async -> Bool
}

@MainActor
final class KindleOfflineDownloadCoordinator: ObservableObject {
    @Published private(set) var book: KindleOfflineBook?
    @Published private(set) var isRunning = false
    @Published private(set) var phase = "准备保存整本书"
    @Published private(set) var error: String?
    private let store: KindleOfflineBookStore
    private var task: Task<Void, Never>?
    private var runID = UUID()

    init(store: KindleOfflineBookStore = .shared) { self.store = store }

    func refresh(sourceBookID: String, scope: String) async {
        guard !isRunning else { return }
        do { book = try await store.load(id: KindleOfflineBookStore.bookID(sourceBookID), scope: scope) }
        catch { self.error = "本机下载记录读取失败。" }
    }

    func start(source: any KindleOfflineBookSource, scope: String, stillAuthorized: @escaping @MainActor () -> Bool) {
        guard !isRunning else { return }
        let run = UUID(); runID = run
        isRunning = true
        error = nil
        phase = "正在确认整本书的页范围…"
        task = Task { [weak self, source] in
            guard let self else { return }
            let priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = priorIdleTimer }
            var capturedSession = false
            do {
                guard stillAuthorized() else { throw CancellationError() }
                let prior = try await self.store.load(id: KindleOfflineBookStore.bookID(source.offlineSourceBook.id), scope: scope)
                let interruptedPosition = prior?.originalPositionRestored == false ? prior?.originalPosition : nil
                capturedSession = true
                let original = try await source.beginOfflineBookCapture(restoring: interruptedPosition)
                try Task.checkCancellation()
                guard stillAuthorized(), self.runID == run else { throw CancellationError() }
                var book = try await self.store.prepare(source: source.offlineSourceBook, scope: scope, originalPosition: original)
                self.book = book
                if book.status != .complete {
                    // There is deliberately no page budget. The source's final
                    // position and a continuous range chain define completion.
                    while true {
                        try Task.checkCancellation()
                        guard stillAuthorized(), self.runID == run else { throw CancellationError() }
                        if book.coversWholeBook { break }
                        self.phase = "正在保存第 \(book.pages.count + 1) 页…"
                        let captured = try await source.captureOfflineBookPage(after: book.pages.last?.position)
                        try Task.checkCancellation()
                        guard stillAuthorized(), self.runID == run else { throw CancellationError() }
                        book = try await self.store.append(document: captured.document, position: captured.position, to: book, scope: scope)
                        self.book = book
                    }
                    self.phase = "正在校验整本书…"
                    book = try await self.store.finish(book, scope: scope)
                    self.book = book
                }
                self.phase = "整本已保存 · \(book.pages.count) 页"
            } catch {
                let paused = Task.isCancelled || error is CancellationError
                let message = paused ? "已暂停，已保存页面会保留。" : Self.message(for: error)
                if let book = self.book {
                    self.book = (try? await self.store.setStatus(paused ? .paused : .failed, error: message, book: book, scope: scope)) ?? book
                }
                self.error = paused ? nil : message
                self.phase = message
            }
            if capturedSession {
                // Cleanup must still run after cancellation. The source owns
                // its session and checks its account/reader generation itself.
                let restored = await Task { @MainActor in await source.endOfflineBookCapture() }.value
                if let book = self.book {
                    self.book = (try? await self.store.setStatus(book.status, error: book.lastError,
                        book: book, scope: scope, originalRestored: restored)) ?? book
                }
                if !restored { self.error = "下载记录已保留，返回在线阅读时请确认原阅读位置。" }
            }
            if self.runID == run { self.isRunning = false; self.task = nil }
        }
    }

    func pause() { task?.cancel() }

    private static func message(for error: Error) -> String {
        if let failure = error as? KindleOfflineBookStore.Failure {
            switch failure {
            case .discontinuousPage, .incompleteBook: return "页面范围未能连续确认，下载已停止，已有内容保留。"
            case .staleGeneration: return "书籍版式已变化，请恢复下载时的版式后继续。"
            case .invalidIdentity: return "账号已变化，请重新打开当前账号的书籍。"
            case .corruptManifest: return "本机下载记录校验失败。"
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteOutOfSpaceError {
            return "手机空间不足，已保存页面保留，释放空间后可以继续。"
        }
        return "本页暂时无法保存。请确认网络和 Kindle 页面正常后继续下载，已有页面会保留。"
    }
}
