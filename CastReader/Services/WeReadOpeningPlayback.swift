import Foundation

/// Only advance a positively identified non-text surface, once per identity.
/// The live bridge supplies evidence; no chapter text or access controls are
/// inferred, bypassed or fetched here. Cancellation also owns late web replies.
@MainActor
enum WeReadOpeningPlayback {
    enum Page: Equatable {
        case ready
        case waiting
        case cover(String)
        case unavailable
    }

    static func prepare(
        maximumProbes: Int = 60,
        delayNanoseconds: UInt64 = 300_000_000,
        probe: () async -> Page,
        advance: (String) async -> Bool,
        allowed: () -> Bool
    ) async -> Bool {
        var previous: Page = .waiting
        var stableCount = 0
        var visited = Set<String>()
        for _ in 0..<maximumProbes {
            guard !Task.isCancelled, allowed() else { return false }
            let page = await probe()
            guard !Task.isCancelled, allowed() else { return false }
            if page == .ready { return true }
            if page == .unavailable { return false }
            stableCount = page == previous ? stableCount + 1 : 1
            previous = page
            if case .cover(let identity) = page, !identity.isEmpty,
               stableCount >= 3, !visited.contains(identity) {
                guard visited.count < 4 else { return false }
                visited.insert(identity)
                guard await advance(identity) else { return false }
            }
            do { try await Task.sleep(nanoseconds: delayNanoseconds) }
            catch { return false }
        }
        return false
    }
}
