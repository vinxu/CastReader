import Foundation

/// A dispatched Kindle React action cannot be undone by cancelling its Swift
/// caller. Serialize button actions through confirmation before observing the
/// next old page. Cancellation still revokes pending playback/navigation work.
@MainActor
final class KindleManualPageTurnQueue {
    private var tail: Task<Void, Never>?
    private var tailID: UUID?
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private var activeID: UUID?

    func perform(_ operation: @escaping @MainActor () async -> Void) async {
        let predecessor = tail
        let owner = generation
        let id = UUID()
        let task = Task { @MainActor in
            await predecessor?.value
            guard !Task.isCancelled, self.generation == owner else { return }
            self.activeID = id
            defer { if self.activeID == id { self.activeID = nil } }
            await operation()
        }
        tail = task
        tailID = id
        pending[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        pending[id] = nil
        if tailID == id { tail = nil; tailID = nil }
    }

    func cancel() {
        generation &+= 1
        for (id, task) in pending where id != activeID { task.cancel() }
        // The active operation keeps waiting for its dispatched action. The
        // reader's navigation epoch rejects its result after pause/close.
        // Retain the tail until its already-dispatched WebKit action unwinds.
        // A new request must not overlap that action after stop/resume either.
    }
}
