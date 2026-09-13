import Foundation
import UIKit

struct KindleOfflineCapturedPage {
    let position: KindleOfflineSourcePosition
    let document: ReadingDocument
    var requiresOCR = false
    var sourceWordCount: Int?
}

enum KindleOfflineCaptureFailure: Error { case pageNotReady }

@MainActor
protocol KindleOfflineBookSource: AnyObject {
    var offlineSourceBook: KindleBook { get }
    func beginOfflineBookCapture(restoring interruptedPosition: KindleOfflineSourcePosition?) async throws -> KindleOfflineSourcePosition
    func captureOfflineBookPage(after: KindleOfflineSourcePosition?) async throws -> KindleOfflineCapturedPage
    func endOfflineBookCapture() async -> Bool
}

/// Estimates only the remaining source range in this run, including a resumed
/// run. The first few pages are samples, not a promised whole-book duration.
struct KindleOfflineDownloadEstimate {
    private var samples: [(time: TimeInterval, fraction: Double)] = []
    private(set) var remainingSeconds: Int?

    mutating func record(fraction: Double, at time: TimeInterval) {
        guard fraction.isFinite, time.isFinite, (0...1).contains(fraction) else { return }
        if let last = samples.last, time <= last.time || fraction <= last.fraction { return }
        samples.append((time, fraction))
        while samples.count > 4, let first = samples.first, time - first.time > 12 { samples.removeFirst() }
        guard samples.count >= 4, let first = samples.first, time - first.time >= 2,
              fraction > first.fraction else { remainingSeconds = nil; return }
        let value = (1 - fraction) * (time - first.time) / (fraction - first.fraction)
        // Round upward and reserve a small amount of time for final validation.
        remainingSeconds = Int(ceil(min(86_400, max(0, value)) / 5)) * 5 + 5
    }
}

@MainActor
final class KindleOfflineDownloadCoordinator: ObservableObject {
    enum Activity { case idle, preparing, saving, verifying, restoring }
    enum StopReason {
        case user, background, closing
        var message: String {
            switch self {
            case .user, .closing: return AppLocalized("已取消本次下载，已保存页面会保留。")
            case .background: return AppLocalized("已暂停。请保持此页面在前台，已保存页面会保留。")
            }
        }
    }
    @Published private(set) var book: KindleOfflineBook?
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var activity = Activity.idle
    @Published private(set) var estimatedRemainingSeconds: Int?
    @Published private(set) var phase = AppLocalized("准备保存整本书")
    @Published private(set) var error: String?
    let store: KindleOfflineBookStore
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var stopReason: StopReason?

    init(store: KindleOfflineBookStore = .shared) { self.store = store }

    func refresh(sourceBookID: String, scope: String) async {
        guard !isRunning else { return }
        do {
            let saved = try await store.load(id: KindleOfflineBookStore.bookID(sourceBookID), scope: scope)
            if !isRunning { book = saved }
        } catch { if !isRunning { self.error = AppLocalized("本机下载记录读取失败。") } }
    }

    func start(source: any KindleOfflineBookSource, scope: String, stillAuthorized: @escaping @MainActor () -> Bool) {
        guard !isRunning else { return }
        let run = UUID(); runID = run
        isRunning = true
        isStopping = false; stopReason = nil; activity = .preparing
        estimatedRemainingSeconds = nil
        error = nil
        phase = AppLocalized("正在确认整本书的页范围…")
        task = Task { [weak self, source] in
            guard let self else { return }
            let priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            let orientationOwner = "kindle-offline-download-" + run.uuidString
            AppOrientationLock.lockCurrent(owner: orientationOwner)
            defer {
                UIApplication.shared.isIdleTimerDisabled = priorIdleTimer
                AppOrientationLock.unlock(owner: orientationOwner)
            }
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
                var estimate = KindleOfflineDownloadEstimate()
                // The first captured page can include a one-time seek from the
                // reading position. Start throughput samples after it commits.
                if book.status != .complete {
                    // There is deliberately no page budget. The source's final
                    // position and a continuous range chain define completion.
                    while true {
                        try Task.checkCancellation()
                        guard stillAuthorized(), self.runID == run else { throw CancellationError() }
                        if book.coversWholeBook { break }
                        self.activity = .saving
                        self.phase = AppLocalized("正在保存第 \(book.pages.count + 1) 页…")
                        let started = ProcessInfo.processInfo.systemUptime
                        let captured = try await self.captureWithRetry(source: source, after: book.pages.last?.position,
                            ordinal: book.pages.count + 1, stillAuthorized: stillAuthorized)
                        let capturedAt = ProcessInfo.processInfo.systemUptime
                        try Task.checkCancellation()
                        guard stillAuthorized(), self.runID == run else { throw CancellationError() }
                        book = try await self.store.append(document: captured.document, position: captured.position,
                            to: book, scope: scope, requiresOCR: captured.requiresOCR, sourceWordCount: captured.sourceWordCount)
                        self.book = book
                        let savedAt = ProcessInfo.processInfo.systemUptime
                        estimate.record(fraction: book.downloadFraction, at: savedAt)
                        self.estimatedRemainingSeconds = estimate.remainingSeconds
                        KindleRunLog.write("KINDLE_OFFLINE_TIMING page=\(book.pages.count) captureMs=\(Int((capturedAt-started)*1000)) saveMs=\(Int((savedAt-capturedAt)*1000))")
                    }
                    self.activity = .verifying
                    self.estimatedRemainingSeconds = nil
                    self.phase = AppLocalized("正在校验整本书…")
                    book = try await self.store.finish(book, scope: scope)
                    self.book = book
                }
                self.phase = AppLocalized("整本已保存 · \(book.pages.count) 页")
            } catch {
                let paused = Task.isCancelled || error is CancellationError
                let message = paused ? (self.stopReason?.message ?? "已暂停，已保存页面会保留。") : Self.message(for: error)
                if let book = self.book {
                    self.book = (try? await self.store.setStatus(paused ? .paused : .failed, error: message, book: book, scope: scope)) ?? book
                }
                self.error = paused ? nil : message
                self.phase = message
            }
            if capturedSession {
                let outcome = self.phase
                self.activity = .restoring
                self.estimatedRemainingSeconds = nil
                self.phase = AppLocalized("正在恢复原阅读位置…")
                // Cleanup must still run after cancellation. The source owns
                // its session and checks its account/reader generation itself.
                let restored = await Task { @MainActor in await source.endOfflineBookCapture() }.value
                if let book = self.book {
                    self.book = (try? await self.store.setStatus(book.status, error: book.lastError,
                        book: book, scope: scope, originalRestored: restored)) ?? book
                }
                if !restored { self.error = AppLocalized("下载记录已保留，返回在线阅读时请确认原阅读位置。") }
                self.phase = outcome
            }
            if self.runID == run {
                self.isRunning = false; self.isStopping = false; self.activity = .idle
                self.estimatedRemainingSeconds = nil; self.task = nil
            }
        }
    }

    func pause(reason: StopReason = .user) {
        guard isRunning, !isStopping, activity != .restoring else { return }
        stopReason = reason
        isStopping = true; estimatedRemainingSeconds = nil
        phase = AppLocalized("正在停止下载…")
        task?.cancel()
    }

    func stopAndWait(reason: StopReason = .user) async {
        let pending = task
        pause(reason: reason)
        await pending?.value
    }

    private func captureWithRetry(source: any KindleOfflineBookSource, after previous: KindleOfflineSourcePosition?,
                                  ordinal: Int, stillAuthorized: @MainActor () -> Bool) async throws -> KindleOfflineCapturedPage {
        for attempt in 0...2 {
            try Task.checkCancellation()
            guard stillAuthorized() else { throw CancellationError() }
            do { return try await source.captureOfflineBookPage(after: previous) }
            catch KindleOfflineCaptureFailure.pageNotReady {
                try Task.checkCancellation()
                guard attempt < 2 else { throw KindleOfflineCaptureFailure.pageNotReady }
                // Re-request the same uncommitted source range. The source's
                // exact move/advance guard prevents a retry from skipping a page.
                phase = AppLocalized("正在重试第 \(ordinal) 页（\(attempt + 1)/2）…")
                estimatedRemainingSeconds = nil
                KindleRunLog.write("KINDLE_OFFLINE_RETRY page=\(ordinal) attempt=\(attempt + 1) reason=page-not-ready")
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw KindleOfflineCaptureFailure.pageNotReady
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? KindleOfflineBookStore.Failure {
            switch failure {
            case .discontinuousPage, .incompleteBook: return AppLocalized("页面范围未能连续确认，下载已停止，已有内容保留。")
            case .staleGeneration: return AppLocalized("书籍版式已变化，请恢复下载时的版式后继续。")
            case .invalidIdentity: return AppLocalized("账号已变化，请重新打开当前账号的书籍。")
            case .corruptManifest: return AppLocalized("本机下载记录校验失败。")
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteOutOfSpaceError {
            return AppLocalized("手机空间不足，已保存页面保留，释放空间后可以继续。")
        }
        return AppLocalized("本页暂时无法保存。请确认网络和 Kindle 页面正常后继续下载，已有页面会保留。")
    }
}
