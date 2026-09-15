import Foundation

/// One admission budget for preset speech, shared by playback and speculative
/// page preparation. Keep an urgent slot available while a page is downloading.
/// Admitted requests are never cancelled merely to reorder the queue.
actor PresetTTSRequestScheduler {
    static let shared = PresetTTSRequestScheduler()

    enum Priority: Int, Sendable {
        case interactive = 0
        case readAhead = 1
        case speculative = 2
    }

    private struct Waiter {
        let id: UUID
        let requestID: String
        let priority: Priority
        let queuedAt: TimeInterval
        let continuation: CheckedContinuation<UUID, Error>
    }

    private let maximumActive: Int
    private let protectInteractive: Bool
    private var active: [UUID: Priority] = [:]
    private var waiting: [Waiter] = []

    init(maximumActive: Int = 2, protectInteractive: Bool = false) {
        precondition(maximumActive > 0)
        self.maximumActive = maximumActive
        self.protectInteractive = protectInteractive
    }

    func run<T>(
        priority: Priority,
        requestID: String,
        operation: () async throws -> T
    ) async throws -> T {
        let permit = try await acquire(priority: priority, requestID: requestID)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(permit)
            return result
        } catch {
            release(permit)
            throw error
        }
    }

    func acquire(priority: Priority, requestID: String) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(id: id, requestID: requestID, priority: priority,
                                    queuedAt: ProcessInfo.processInfo.systemUptime,
                                    continuation: continuation)
                // Insertion is stable within one priority. Request arrival order
                // must not let speculative pages jump ahead of pending playback.
                let index = waiting.firstIndex { $0.priority.rawValue > priority.rawValue } ?? waiting.endIndex
                waiting.insert(waiter, at: index)
                drain()
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    func release(_ permit: UUID) {
        guard active.removeValue(forKey: permit) != nil else { return }
        drain()
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiting.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        drain()
        // If already admitted, run() retains its permit until the underlying
        // URLSession operation actually exits. Cancellation cannot oversubscribe.
    }

    private func drain() {
        while active.count < maximumActive {
            guard let index = waiting.firstIndex(where: {
                if protectInteractive, $0.priority != .interactive {
                    // A clone may need a cold prompt restored. Do not launch
                    // duplicate background preparation while first audio waits.
                    return active.isEmpty
                }
                return $0.priority != .speculative || !active.values.contains(.speculative)
            }) else { return }
            let waiter = waiting.remove(at: index)
            active[waiter.id] = waiter.priority
            #if DEBUG
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - waiter.queuedAt) * 1_000)
            ReaderRunLog.write("TTS schedule dispatch request=\(waiter.requestID) priority=\(waiter.priority) queueMs=\(elapsed) active=\(active.count) pending=\(waiting.count)")
            #endif
            waiter.continuation.resume(returning: waiter.id)
        }
    }

    #if DEBUG
    var debugCounts: (active: Int, waiting: Int) { (active.count, waiting.count) }
    #endif
}
