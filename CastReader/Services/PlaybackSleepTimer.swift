import Foundation
import Combine

/// A wall-clock deadline shared by every content player. Expiration also leaves
/// a playback latch: cancelling the UI timer must not let a late TTS callback
/// or a page handoff resume audio without a new Play action.
final class PlaybackSleepTimer: ObservableObject {
    @Published private(set) var deadline: Date?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var requiresExplicitResume = false
    var onExpiration: (() -> Void)?

    private let now: () -> Date
    private let schedulesTicks: Bool
    private var ticker: Timer?

    init(now: @escaping () -> Date = Date.init, schedulesTicks: Bool = true) {
        self.now = now
        self.schedulesTicks = schedulesTicks
    }

    var isActive: Bool { deadline != nil }

    var countdown: String {
        let seconds = max(0, remainingSeconds)
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func start(after seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        start(until: now().addingTimeInterval(seconds))
    }

    func start(until date: Date) {
        guard date > now() else { return }
        ticker?.invalidate()
        deadline = date
        checkDeadline()
        guard schedulesTicks, isActive else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkDeadline()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        deadline = nil
        remainingSeconds = 0
    }

    func endPlaybackSession() {
        cancel()
        requiresExplicitResume = false
    }

    func resumeByUser() {
        checkDeadline()
        requiresExplicitResume = false
    }

    @discardableResult
    func permitsAutomaticPlayback() -> Bool {
        checkDeadline()
        return !requiresExplicitResume
    }

    func checkDeadline() {
        guard let deadline else { return }
        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(now()))))
        if remainingSeconds != seconds { remainingSeconds = seconds }
        guard seconds == 0 else { return }
        requiresExplicitResume = true
        cancel()
        onExpiration?()
    }

    static func nextStopTime(_ time: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(60)
    }

    deinit { ticker?.invalidate() }
}
