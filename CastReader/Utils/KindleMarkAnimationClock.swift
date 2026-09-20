import Foundation
import SwiftUI

/// One monotonic timeline survives the live SVG → held page handoff. Drawing
/// history and waiting ownership are separate: pausing cancels a turn, not ink.
@MainActor
final class KindleMarkAnimationClock: ObservableObject {
    struct Animation {
        let startedAt: TimeInterval
        let duration: TimeInterval

        func progress(at now: TimeInterval) -> CGFloat {
            let x = min(1, max(0, (now - startedAt) / duration))
            // CSS/SwiftUI ease-out: cubic-bezier(0, 0, .58, 1).
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let t = (low + high) / 2
                let bx = 3 * (1 - t) * t * t * 0.58 + t * t * t
                if bx < x { low = t } else { high = t }
            }
            let t = (low + high) / 2
            return CGFloat(3 * (1 - t) * t * t + t * t * t)
        }
    }
    @Published private(set) var animations: [UUID: Animation] = [:]
    private(set) var generation: UInt64 = 0
    static let maximumWait: TimeInterval = 2.32 // 2.2s pen + final frame margin

    func begin(_ id: UUID, duration: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard animations[id] == nil, duration.isFinite, duration > 0 else { return }
        animations[id] = Animation(startedAt: now, duration: min(2.2, duration))
    }

    func cancelWaits() { generation &+= 1 }
    func reset() { cancelWaits(); animations.removeAll() }

    func remaining(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, min(Self.maximumWait, (animations.values.map { $0.startedAt + $0.duration + 0.12 }.max() ?? now) - now))
    }

    /// No renderer callback is required to unlock navigation. Never wait longer
    /// than a full pen animation, even if WebKit disappears or stops painting.
    func drain(while isCurrent: () -> Bool) async -> Bool {
        let owner = generation
        let deadline = ProcessInfo.processInfo.systemUptime + Self.maximumWait
        while true {
            guard !Task.isCancelled, generation == owner, isCurrent() else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            let delay = min(remaining(at: now), deadline - now)
            if delay <= 0 { return true }
            do { try await Task.sleep(nanoseconds: UInt64(min(0.04, delay) * 1_000_000_000)) }
            catch { return false }
        }
    }
}

/// The held page reads the same elapsed phase as the live SVG. A renderer
/// switch cannot mark a merely-triggered stroke as already finished.
struct KindleTimedMarkInkView: View {
    let ink: HandwrittenMark.Stroke
    let animation: KindleMarkAnimationClock.Animation?

    @State private var finished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: finished || animation == nil)) { _ in
            ink.path.trimmedPath(from: 0, to: animation?.progress(at: ProcessInfo.processInfo.systemUptime) ?? 0)
                .stroke(Color(red: 253 / 255, green: 95 / 255, blue: 1 / 255).opacity(ink.opacity),
                        style: StrokeStyle(lineWidth: ink.lineWidth, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .task(id: animation?.startedAt) {
            guard let animation else { return }
            finished = false
            let remaining = max(0, animation.startedAt + animation.duration - ProcessInfo.processInfo.systemUptime)
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            catch { return }
            finished = true
        }
    }
}
