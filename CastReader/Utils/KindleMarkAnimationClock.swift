import Foundation
import SwiftUI
import UIKit

/// A fixed delay cannot prove that SwiftUI removed the old page. Wait for that
/// exact view's removal and a subsequent displayed frame, with bounded failure
/// when the scene no longer renders. Source/geometry validation stays in the
/// Kindle coordinator; this fence only owns native raster removal.
@MainActor
final class KindleVisualHoldReleaseFence: NSObject {
    private var holdID: UUID?
    private var removedAt: CFTimeInterval?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var displayLink: CADisplayLink?
    private var timeout: DispatchWorkItem?
    private var isCurrent: (() -> Bool)?

    func waitForRemoval(of id: UUID, timeoutSeconds: TimeInterval = 1,
                        while isCurrent: @escaping () -> Bool,
                        remove: () -> Void) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finish(false)
                holdID = id
                self.continuation = continuation
                self.isCurrent = isCurrent
                let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
                displayLink = link
                link.add(to: .main, forMode: .common)
                let timeout = DispatchWorkItem { [weak self] in
                    guard self?.holdID == id else { return }
                    self?.finish(false)
                }
                self.timeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
                remove()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.holdID == id else { return }
                self?.finish(false)
            }
        }
    }

    func didRemove(_ id: UUID) {
        guard holdID == id, removedAt == nil else { return }
        removedAt = CACurrentMediaTime()
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard isCurrent?() == true else { finish(false); return }
        // timestamp describes the last displayed frame, not the future frame
        // about to be drawn by this callback.
        if let removedAt, link.timestamp > removedAt { finish(true) }
    }

    private func finish(_ result: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        timeout?.cancel()
        timeout = nil
        let pending = continuation
        continuation = nil
        holdID = nil
        removedAt = nil
        isCurrent = nil
        pending?.resume(returning: result)
    }
}

/// Dismantling the exact mounted hold is stronger evidence than observing the
/// model property becoming nil: SwiftUI may not have rendered that change yet.
struct KindleVisualHoldRemovalObserver: UIViewRepresentable {
    let id: UUID
    let fence: KindleVisualHoldReleaseFence
    final class Coordinator {
        let id: UUID
        let fence: KindleVisualHoldReleaseFence
        init(id: UUID, fence: KindleVisualHoldReleaseFence) { self.id = id; self.fence = fence }
    }
    func makeCoordinator() -> Coordinator { Coordinator(id: id, fence: fence) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.fence.didRemove(coordinator.id)
    }
}

/// One monotonic timeline survives the live SVG → held page handoff. Drawing
/// history and waiting ownership are separate: pausing cancels a turn, not ink.
@MainActor
final class KindleMarkAnimationClock: ObservableObject {
    struct Animation: Equatable {
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

    func begin(_ id: UUID, duration: TimeInterval, completeBy: TimeInterval? = nil,
               now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard animations[id] == nil, duration.isFinite, duration > 0 else { return }
        var fittedDuration = min(2.2, duration)
        if let completeBy, completeBy.isFinite {
            // A known final audio tail includes the pen and its final frame.
            // Keep drawing the complete path, but do not append a full-speed
            // two-second stroke after a fast narrator has already finished.
            fittedDuration = min(fittedDuration, max(0.01, completeBy - now - 0.12))
        }
        animations[id] = Animation(startedAt: now, duration: fittedDuration)
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
