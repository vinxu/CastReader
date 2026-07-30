//
//  ResumeReminderManager.swift
//  CastReader
//
//  「继续听」本地通知召回：用户有听到一半的内容而离开时，24 小时后提醒回来接着听。
//
//  设计约束（防骚扰是产品底线，比触达率优先）：
//  - 只对**真实听过 ≥60s** 的内容提醒（时长来自播放 tick 管线，拖动/跳转的大 delta 不计入）；
//  - 单内容一生最多 2 次、两次间隔 ≥7 天；全局 ≤1 条/天；离开 24h 后才响；
//  - 回前台立刻取消所有待发提醒——人已经回来，迟到的提醒只会显得愚蠢；
//  - 权限在**首次累计 180s 有效收听后**的下一次回前台时请求（此刻用户已被产品说服），
//    绝不在首启弹窗；用户拒绝即永久沉默。
//
//  刻意不做（v1）：自定义深链（点按只打开 App，首页各 rail 自带「继续」入口）、
//  服务端推送、启动归因埋点（本地通知拿不到可靠的打开归因，宁缺毋滥）。
//

import Foundation
import UserNotifications
import UIKit

// MARK: - 纯策略层（可单测，无系统依赖）

struct ResumeReminderCandidate: Equatable {
    let id: String
    let title: String
    let listenedSeconds: Double
    let lastListenedAt: Date
}

struct ResumeReminderPolicy {
    /// 内容够格被提醒的最少真实收听秒数。
    var minListenedSeconds: Double = 60
    /// 只提醒「新鲜」的中断：最后收听距今超过该窗口就不再打扰（意图已冷）。
    var freshWindow: TimeInterval = 72 * 3600
    /// 距最后收听多久后提醒。
    var reminderDelay: TimeInterval = 24 * 3600
    /// 计算出的触发时刻至少离现在这么远（避免刚锁屏就响）。
    var minLeadTime: TimeInterval = 6 * 3600
    /// 单内容一生最多提醒次数。
    var perDocLifetimeCap: Int = 2
    /// 同一内容两次提醒的最小间隔。
    var perDocCooldown: TimeInterval = 7 * 24 * 3600
    /// 全局任意两条提醒的最小间隔（≤1 条/天）。
    var globalMinInterval: TimeInterval = 20 * 3600
    /// 请求通知权限所需的累计有效收听秒数。
    var permissionPromptThreshold: Double = 180

    /// 单次播放 delta 的可信上限：与评分/引导管线同一口径，
    /// 大于该值视为拖动或时间跳变，不计入真实收听。
    static let maxTrustedDelta: Double = 2.01

    /// 返回应当调度的触发时刻；nil = 不打扰。
    func fireDate(
        now: Date,
        candidate: ResumeReminderCandidate,
        sentForDoc: [Date],
        lastSentAny: Date?
    ) -> Date? {
        guard candidate.listenedSeconds >= minListenedSeconds else { return nil }
        guard now.timeIntervalSince(candidate.lastListenedAt) <= freshWindow else { return nil }
        guard sentForDoc.count < perDocLifetimeCap else { return nil }
        if let lastForDoc = sentForDoc.max(),
           now.timeIntervalSince(lastForDoc) < perDocCooldown { return nil }

        var fire = max(
            candidate.lastListenedAt.addingTimeInterval(reminderDelay),
            now.addingTimeInterval(minLeadTime)
        )
        // 全局频控：顺延到距上一条足够远，而不是直接放弃（顺延后仍受新鲜窗约束）。
        if let lastAny = lastSentAny {
            fire = max(fire, lastAny.addingTimeInterval(globalMinInterval))
        }
        guard fire.timeIntervalSince(candidate.lastListenedAt) <= freshWindow + reminderDelay else { return nil }
        return fire
    }

    /// 多个候选时提醒哪一个：最近听过的优先（意图最新）。
    static func pick(_ candidates: [ResumeReminderCandidate]) -> ResumeReminderCandidate? {
        candidates.max { $0.lastListenedAt < $1.lastListenedAt }
    }
}

// MARK: - 持久化状态

private struct ResumeReminderDocState: Codable {
    var title: String
    var listenedSeconds: Double
    var lastListenedAt: Date
}

private struct ResumeReminderState: Codable {
    var totalListenedSeconds: Double = 0
    var didRequestPermission = false
    var shouldPromptPermission = false
    var perDoc: [String: ResumeReminderDocState] = [:]
    var sentAt: [String: [Date]] = [:]
    var lastSentAt: Date?
}

// MARK: - Manager

@MainActor
final class ResumeReminderManager {
    static let shared = ResumeReminderManager()

    private static let stateKey = "resumeReminder.v1.state"
    private static let requestPrefix = "resume."
    private static let maxTrackedDocs = 20

    private let policy = ResumeReminderPolicy()
    private var state = ResumeReminderState()
    private var appInBackground = false
    private var lastBackgroundReschedule = Date.distantPast

    private init() { load() }

    func start() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.appDidEnterBackground() }
        }
    }

    // MARK: 播放时长（与评分/引导同一 tick 管线，主线程回调）

    func recordPlayback(documentID: String, title: String, seconds: Double) {
        guard seconds.isFinite, seconds > 0, seconds <= ResumeReminderPolicy.maxTrustedDelta,
              !documentID.isEmpty else { return }
        let now = Date()
        state.totalListenedSeconds += seconds
        var doc = state.perDoc[documentID] ?? ResumeReminderDocState(
            title: title, listenedSeconds: 0, lastListenedAt: now
        )
        doc.listenedSeconds += seconds
        doc.lastListenedAt = now
        if !title.isEmpty { doc.title = title }
        state.perDoc[documentID] = doc
        trimTrackedDocs()

        if !state.didRequestPermission,
           state.totalListenedSeconds >= policy.permissionPromptThreshold {
            state.shouldPromptPermission = true
        }
        persistThrottled(now: now)

        // 后台播放是常态：锁屏听书时定期刷新调度，让触发点始终锚定「最后收听 +24h」，
        // 而不是锚定几小时前进后台的那一刻。
        if appInBackground, now.timeIntervalSince(lastBackgroundReschedule) > 300 {
            lastBackgroundReschedule = now
            scheduleIfEligible()
        }
    }

    // MARK: 前后台

    func appBecameActive() {
        appInBackground = false
        // 人回来了，待发的「回来听」提醒全部作废。
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        promptPermissionIfNeeded()
    }

    private func appDidEnterBackground() {
        appInBackground = true
        lastBackgroundReschedule = Date()
        persist()
        scheduleIfEligible()
    }

    // MARK: 权限

    private func promptPermissionIfNeeded() {
        guard state.shouldPromptPermission, !state.didRequestPermission else { return }
        state.didRequestPermission = true
        state.shouldPromptPermission = false
        persist()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: 调度

    private func scheduleIfEligible() {
        let now = Date()
        let candidates = state.perDoc.map { id, doc in
            ResumeReminderCandidate(
                id: id, title: doc.title,
                listenedSeconds: doc.listenedSeconds, lastListenedAt: doc.lastListenedAt
            )
        }
        guard let candidate = ResumeReminderPolicy.pick(candidates),
              let fire = policy.fireDate(
                  now: now,
                  candidate: candidate,
                  sentForDoc: state.sentAt[candidate.id] ?? [],
                  lastSentAny: state.lastSentAt
              ) else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = candidate.title.isEmpty ? AppLocalized("继续听") : candidate.title
            content.body = AppLocalized("上次还没听完，接着听？")
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(60, fire.timeIntervalSince(now)), repeats: false
            )
            let request = UNNotificationRequest(
                identifier: Self.requestPrefix + candidate.id, content: content, trigger: trigger
            )
            center.removeAllPendingNotificationRequests()   // 同时只保留一条
            center.add(request) { error in
                guard error == nil else { return }
                Task { @MainActor in self.markScheduled(docID: candidate.id, fireAt: fire) }
            }
        }
    }

    /// 调度成功即计入频控。提醒可能被系统或用户回前台取消，但按「已尝试」计数
    /// 是防骚扰的正确方向：宁可少提醒，不可用「没送达」当理由重复轰炸。
    private func markScheduled(docID: String, fireAt: Date) {
        var sent = state.sentAt[docID] ?? []
        sent.append(fireAt)
        state.sentAt[docID] = Array(sent.suffix(policy.perDocLifetimeCap))
        state.lastSentAt = fireAt
        persist()
    }

    // MARK: 持久化

    private func trimTrackedDocs() {
        guard state.perDoc.count > Self.maxTrackedDocs else { return }
        let keep = state.perDoc.sorted { $0.value.lastListenedAt > $1.value.lastListenedAt }
            .prefix(Self.maxTrackedDocs)
        state.perDoc = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private var lastPersist = Date.distantPast
    private func persistThrottled(now: Date) {
        guard now.timeIntervalSince(lastPersist) > 5 else { return }
        lastPersist = now
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let decoded = try? JSONDecoder().decode(ResumeReminderState.self, from: data) else { return }
        state = decoded
    }
}
