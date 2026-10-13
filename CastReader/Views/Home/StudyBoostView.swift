//
//  StudyBoostView.swift
//  CastReader
//
//  Read and Follow 2026: seven days of verified Read Aloud playback.
//  The App Store event deep link, Home discovery card and persisted progress
//  all share the same source of truth in this file.
//

import Foundation
import SwiftUI
import Combine

enum StudyBoostDeepLink {
    static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "castreader",
              url.host?.lowercased() == "study" else {
            return false
        }
        guard url.path.isEmpty || url.path == "/" else { return false }
        let campaigns = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "campaign" } ?? []
        return campaigns.isEmpty || (campaigns.count == 1 && campaigns[0].value == StudyBoostCampaign.identifier)
    }
}

@MainActor
final class StudyBoostRouter: ObservableObject {
    static let shared = StudyBoostRouter()

    @Published private(set) var isPresented = false

    init() {
        #if DEBUG
        isPresented = ProcessInfo.processInfo.arguments.contains("-CastReaderOpenStudyBoost")
        #endif
    }

    func open() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}

enum StudyBoostPhase: Equatable {
    case upcoming
    case active
    case completed
    case ended
}

struct StudyBoostCampaign {
    static let identifier = "read-follow-2026-11"
    static let dailyGoalSeconds = 30.0
    static let goalDays = 7

    // Exactly matches the App Store schedule in UTC. Day credit uses the
    // reader's local calendar; a timezone change cannot stretch the event.
    static func startDate(in calendar: Calendar) -> Date {
        Date(timeIntervalSince1970: 1794182400) // 2026-11-09T00:00:00Z
    }

    static func endDateExclusive(in calendar: Calendar) -> Date {
        Date(timeIntervalSince1970: 1795392000) // 2026-11-23T00:00:00Z
    }

    static func phase(
        at date: Date,
        completedDays: Int,
        calendar: Calendar
    ) -> StudyBoostPhase {
        if completedDays >= goalDays { return .completed }
        if date < startDate(in: calendar) { return .upcoming }
        if date < endDateExclusive(in: calendar) { return .active }
        return .ended
    }

    static func isDiscoverable(at date: Date, calendar: Calendar) -> Bool {
        date >= startDate(in: calendar).addingTimeInterval(-8 * 86_400)
            && date < endDateExclusive(in: calendar)
    }


}

/// Credits elapsed listening, not seeks, generated duration or stale clocks.
struct StudyBoostPlaybackAccumulator {
    private var previous: (media: String, position: Double, uptime: Double)?

    mutating func advance(media: String?, position: Double, uptime: Double,
                          isPlaying: Bool, isReadAloud: Bool, rate: Double) -> Double {
        guard let media, isPlaying, isReadAloud, position.isFinite,
              uptime.isFinite, rate.isFinite, rate > 0 else {
            previous = nil
            return 0
        }
        let last = previous
        previous = (media, position, uptime)
        guard let last, last.media == media else { return 0 }
        let elapsed = uptime - last.uptime
        let audioDelta = position - last.position
        guard elapsed > 0, elapsed <= 2, audioDelta > 0,
              audioDelta <= elapsed * min(rate, 4) + 0.35 else { return 0 }
        return min(elapsed, audioDelta / rate)
    }
}

@MainActor
final class StudyBoostStore: ObservableObject {
    static let shared = StudyBoostStore()

    @Published private(set) var completedDayKeys: Set<String>
    @Published private(set) var listeningByDay: [String: Double]
    private var observation: AnyCancellable?
    private var accumulator = StudyBoostPlaybackAccumulator()
    private var unflushedSeconds = 0.0

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private let storageKey = "studyBoost.\(StudyBoostCampaign.identifier).completedDays.v1"

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        let restoredListening = (defaults.dictionary(forKey: storageKey + ".seconds") as? [String: Double] ?? [:])
            .filter { $0.value.isFinite && $0.value >= 0 }
        listeningByDay = restoredListening
        completedDayKeys = Set(restoredListening.filter { $0.value >= StudyBoostCampaign.dailyGoalSeconds }.keys)
    }

    var completedDays: Int {
        min(completedDayKeys.count, StudyBoostCampaign.goalDays)
    }

    var progress: Double {
        Double(completedDays) / Double(StudyBoostCampaign.goalDays)
    }

    var phase: StudyBoostPhase {
        StudyBoostCampaign.phase(
            at: now(),
            completedDays: completedDays,
            calendar: calendar
        )
    }

    var isDiscoverable: Bool {
        StudyBoostCampaign.isDiscoverable(at: now(), calendar: calendar)
    }

    var isTodayComplete: Bool {
        completedDayKeys.contains(dayKey(for: now()))
    }

    var todayListeningSeconds: Int {
        min(Int(listeningByDay[dayKey(for: now())] ?? 0), Int(StudyBoostCampaign.dailyGoalSeconds))
    }

    func startTrackingPlayback() {
        guard observation == nil else { return }
        let player = AudioPlayerService.shared
        observation = player.$currentTime.sink { [weak self, weak player] position in
            guard let self, let player else { return }
            let credited = self.accumulator.advance(
                media: player.currentMediaIdentity.map { String(describing: $0) },
                position: position, uptime: ProcessInfo.processInfo.systemUptime,
                isPlaying: player.isPlaying && !player.isBuffering,
                isReadAloud: player.activityPlaybackOwner == .readAloud,
                rate: Double(player.playbackRate)
            )
            if credited > 0 { self.recordListening(seconds: credited) }
        }
    }

    /// The caller supplies only bounded, measured playback deltas. One local
    /// date is credited once, and the previous campaign's keys are untouched.
    @discardableResult
    func recordListening(seconds: Double, at date: Date? = nil) -> Bool {
        let sessionDate = date ?? now()
        guard seconds.isFinite, seconds > 0, seconds <= 2,
              sessionDate >= StudyBoostCampaign.startDate(in: calendar),
              sessionDate < StudyBoostCampaign.endDateExclusive(in: calendar) else { return false }
        let key = dayKey(for: sessionDate)
        guard !completedDayKeys.contains(key), completedDays < StudyBoostCampaign.goalDays else { return false }
        let total = min(StudyBoostCampaign.dailyGoalSeconds, (listeningByDay[key] ?? 0) + seconds)
        listeningByDay[key] = total
        let completed = total >= StudyBoostCampaign.dailyGoalSeconds - 0.0001
        if completed {
            listeningByDay[key] = StudyBoostCampaign.dailyGoalSeconds
            completedDayKeys.insert(key)
        }
        unflushedSeconds += seconds
        if completed || unflushedSeconds >= 1 {
            defaults.set(listeningByDay, forKey: storageKey + ".seconds")
            unflushedSeconds = 0
        }
        return completed
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct StudyBoostCopy: Equatable {
    let title: String
    let badge: String
    let subtitle: String
    let dateRange: String
    let progressTitle: String
    let progressRule: String
    let todayComplete: String
    let upcomingStatus: String
    let activeStatus: String
    let completedStatus: String
    let endedStatus: String
    let stepImportTitle: String
    let stepImportDetail: String
    let stepListenTitle: String
    let stepListenDetail: String
    let stepExplainTitle: String
    let stepExplainDetail: String
    let startCTA: String
    let previewCTA: String
    let continueCTA: String
    let close: String

    static let supportedLanguages = AppLanguage.allCases.filter { $0 != .system }

    static func localized(
        for selectedLanguage: AppLanguage,
        locale: Locale = .autoupdatingCurrent
    ) -> StudyBoostCopy {
        let code = selectedLanguage == .system ? locale.identifier : selectedLanguage.rawValue
        let canonical = SupportedTTSLanguage(identifier: code)?.rawValue ?? "en"
        let localization = ["zh": "zh-Hans", "pt": "pt-BR"][canonical] ?? canonical
        let bundle = Bundle.main.path(forResource: localization, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        func copy(_ key: String, _ fallback: String) -> String {
            bundle.localizedString(forKey: "studyBoost." + key, value: fallback, table: "Localizable")
        }
        return .init(
            title: copy("title", "Read and Follow: Seven Days"),
            badge: copy("badge", "LIMITED-TIME CHALLENGE"),
            subtitle: copy("subtitle", "Listen for 30 seconds on 7 different days"),
            dateRange: copy("dateRange", "Nov 9–22, 2026 (UTC)"),
            progressTitle: copy("progressTitle", "Your listening days"),
            progressRule: copy("progressRule", "30 seconds of actual Read Aloud completes one day. Standard usage limits apply."),
            todayComplete: copy("todayComplete", "Today’s study day is complete"),
            upcomingStatus: copy("upcomingStatus", "Starts November 9. Preview reading now; progress begins when the event starts."),
            activeStatus: copy("activeStatus", "Listen to your own text and follow the words. Pauses and seeking do not count."),
            completedStatus: copy("completedStatus", "Challenge complete! You reached 7 study days."),
            endedStatus: copy("endedStatus", "This challenge has ended, but Study mode is still available."),
            stepImportTitle: copy("stepImportTitle", "Import study material"),
            stepImportDetail: copy("stepImportDetail", "Use files, camera, images, URLs, or text"),
            stepListenTitle: copy("stepListenTitle", "Listen and follow"),
            stepListenDetail: copy("stepListenDetail", "Stay focused with word-by-word highlights"),
            stepExplainTitle: copy("stepExplainTitle", "Understand hard parts"),
            stepExplainDetail: copy("stepExplainDetail", "Optional AI explanations; only Read Aloud counts toward the challenge."),
            startCTA: copy("startCTA", "Start today’s study"),
            previewCTA: copy("previewCTA", "Preview Study mode"),
            continueCTA: copy("continueCTA", "Keep studying"),
            close: copy("close", "Close")
        )
    }

}

struct StudyBoostHomeCard: View {
    let onOpen: () -> Void

    @ObservedObject private var store = StudyBoostStore.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared

    private var copy: StudyBoostCopy {
        .localized(for: appLanguage.selectedLanguage, locale: appLanguage.locale)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 5) {
                    Text(copy.badge)
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(Color.white.opacity(0.84))
                    Text(copy.title)
                        .font(.headline)
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                    Text("\(store.completedDays)/\(StudyBoostCampaign.goalDays) · \(copy.dateRange)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.86))
                }

                Spacer(minLength: 4)
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [AppTheme.primaryDark, AppTheme.primary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: AppTheme.primary.opacity(0.18), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studyBoostHomeCard")
        .accessibilityLabel(Text("\(copy.title). \(copy.subtitle)"))
    }
}

struct StudyBoostView: View {
    let onStartStudy: () -> Void
    let onClose: () -> Void

    @ObservedObject private var store = StudyBoostStore.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared

    private var copy: StudyBoostCopy {
        .localized(for: appLanguage.selectedLanguage, locale: appLanguage.locale)
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    hero
                    progressCard
                    stepsCard
                    primaryAction
                    Text(copy.progressRule)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("studyBoostView")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 62, height: 62)
                    .background(Color.white.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.16))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("studyBoostCloseButton")
                .accessibilityLabel(Text(copy.close))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(copy.badge)
                    .font(.caption.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(Color.white.opacity(0.82))
                Text(copy.title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(Color.white)
                Text(copy.subtitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                Label(copy.dateRange, systemImage: "calendar")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.86))
            }
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [AppTheme.primaryDark, AppTheme.primary, AppTheme.primaryLight],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: AppTheme.primary.opacity(0.22), radius: 22, y: 10)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text(copy.progressTitle)
                    .font(.headline)
                    .foregroundStyle(AppTheme.foreground)
                Spacer()
                Text("\(store.completedDays)/\(StudyBoostCampaign.goalDays)")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(AppTheme.primaryText)
            }

            if store.phase == .active {
                Text("\(store.todayListeningSeconds) / 30 s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedForeground)
                    .accessibilityIdentifier("studyBoostTodaySeconds")
            }
            ProgressView(value: store.progress)
                .tint(AppTheme.primary)
                .scaleEffect(x: 1, y: 1.8, anchor: .center)

            Label(statusText, systemImage: statusIcon)
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            if store.isTodayComplete && store.phase != .upcoming {
                Label(copy.todayComplete, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
            }
        }
        .padding(18)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
        }
        .accessibilityIdentifier("studyBoostProgressCard")
    }

    private var stepsCard: some View {
        VStack(spacing: 0) {
            stepRow(icon: "doc.badge.plus", title: copy.stepImportTitle, detail: copy.stepImportDetail)
            Divider().padding(.leading, 54)
            stepRow(icon: "text.word.spacing", title: copy.stepListenTitle, detail: copy.stepListenDetail)
            Divider().padding(.leading, 54)
            stepRow(icon: "sparkles", title: copy.stepExplainTitle, detail: copy.stepExplainDetail)
        }
        .padding(.horizontal, 16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
        }
    }

    private func stepRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(width: 38, height: 38)
                .background(AppTheme.primary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.foreground)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    private var primaryAction: some View {
        Button(action: onStartStudy) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.doc.fill")
                Text(actionTitle)
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "arrow.forward")
            }
            .font(.headline)
            .foregroundStyle(AppTheme.primaryForeground)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(AppTheme.primary)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: AppTheme.primary.opacity(0.20), radius: 14, y: 7)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studyBoostStartButton")
    }

    private var statusText: String {
        switch store.phase {
        case .upcoming: return copy.upcomingStatus
        case .active: return copy.activeStatus
        case .completed: return copy.completedStatus
        case .ended: return copy.endedStatus
        }
    }

    private var statusIcon: String {
        switch store.phase {
        case .upcoming: return "clock"
        case .active: return "flame.fill"
        case .completed: return "trophy.fill"
        case .ended: return "calendar.badge.checkmark"
        }
    }

    private var actionTitle: String {
        switch store.phase {
        case .upcoming: return copy.previewCTA
        case .active: return copy.startCTA
        case .completed, .ended: return copy.continueCTA
        }
    }
}
