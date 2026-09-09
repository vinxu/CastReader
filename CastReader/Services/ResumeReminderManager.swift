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
//  通知携带内容 id；点按后复用统一 SystemAction 路由回到当前阅读位置，并记录
//  permission/scheduled/opened 三段事件。服务端推送仍不在此模块范围内。
//

import Foundation
@preconcurrency import UserNotifications
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
    var globalMinInterval: TimeInterval = 24 * 3600
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

enum ResumeReminderDeepLink {
    static let actionKey = "castreader_action"
    static let itemIDKey = "castreader_item_id"
    static let continueAction = "continue_reading"

    static func userInfo(documentID: String) -> [AnyHashable: Any] {
        [actionKey: continueAction, itemIDKey: documentID,
         "accountBoundary": SystemActionStore.currentAccountBoundary]
    }

    static func action(from userInfo: [AnyHashable: Any]) -> SystemAction? {
        guard userInfo[actionKey] as? String == continueAction,
              let boundary = userInfo["accountBoundary"] as? String,
              boundary == SystemActionStore.currentAccountBoundary,
              let itemID = (userInfo[itemIDKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemID.isEmpty else { return nil }
        return .continueReading(itemID: itemID, mode: .read)
    }
}

final class ResumeReminderNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ResumeReminderNotificationRouter()

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let action = ResumeReminderDeepLink.action(
            from: response.notification.request.content.userInfo
        ) else { return }
        let didEnqueue = SystemActionStore.shared.enqueue(action, origin: .deepLink)
        Task { @MainActor in
            ProductAnalytics.shared.trackResumeReminder(
                action: .opened,
                result: didEnqueue ? .success : .failed,
                trigger: "d1_continue",
                errorCode: didEnqueue ? nil : "action_enqueue_failed"
            )
        }
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
    private var activeStorageID: String?
    private var scopeGeneration: UInt64 = 0
    private var appInBackground = false
    private var lastBackgroundReschedule = Date.distantPast

    private init() {}

    /// Selects a route x account state before any title or playback duration is
    /// recorded. Switching accounts also cancels the old account's pending
    /// notification immediately, so its title can never surface later.
    func activateAccountScope(storageID: String) {
        guard Self.isValidStorageID(storageID) else {
            deactivateAccountScope()
            return
        }
        guard activeStorageID != storageID else { return }
        clearPendingNotifications()
        scopeGeneration &+= 1
        activeStorageID = storageID
        state = ResumeReminderState()
        lastPersist = .distantPast
        load()
    }

    func deactivateAccountScope() {
        clearPendingNotifications()
        scopeGeneration &+= 1
        activeStorageID = nil
        state = ResumeReminderState()
        lastPersist = .distantPast
    }

    #if DEBUG
    /// UI tests that explicitly bypass the sign-in wall keep the historical
    /// unscoped reminder state. Normal Debug launches remain fail-closed.
    func activateLegacyTestingScope() {
        clearPendingNotifications()
        scopeGeneration &+= 1
        activeStorageID = "debug-legacy"
        state = ResumeReminderState()
        lastPersist = .distantPast
        load()
    }
    #endif

    func start() {
        ResumeReminderNotificationRouter.shared.start()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.appDidEnterBackground() }
        }
    }

    // MARK: 播放时长（与评分/引导同一 tick 管线，主线程回调）

    func recordPlayback(documentID: String, title: String, seconds: Double) {
        guard activeStorageID != nil,
              seconds.isFinite, seconds > 0, seconds <= ResumeReminderPolicy.maxTrustedDelta,
              !documentID.isEmpty else { return }
        let now = Date()
        state.totalListenedSeconds += seconds
        // Per-item listening facts now belong to the atomic checkpoint.
        // Keep only the global permission meter and delivery frequency here.

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
        clearPendingNotifications()
        promptPermissionIfNeeded()
    }

    private func appDidEnterBackground() {
        guard activeStorageID != nil else { return }
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
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            center.getNotificationSettings { settings in
                Task { @MainActor in
                    ProductAnalytics.shared.trackResumeReminder(
                        action: .permissionRequested,
                        result: error != nil ? .failed : (granted ? .success : .denied),
                        permissionStatus: Self.analyticsPermissionStatus(
                            settings.authorizationStatus
                        ),
                        trigger: "after_180s_value",
                        errorCode: error == nil ? nil : "notification_permission_error"
                    )
                }
            }
        }
    }

    // MARK: 调度

    private func scheduleIfEligible() {
        guard appInBackground, let storageID = activeStorageID else { return }
        let expectedGeneration = scopeGeneration
        let now = Date()
        let candidates = ContentCatalog(history: .shared).continuing.compactMap { item -> ResumeReminderCandidate? in
            guard item.availability.permitsReminder else { return nil }
            return ResumeReminderCandidate(id: item.id, title: item.record.title,
                listenedSeconds: item.checkpoint?.activity?.listenedSeconds ?? 0,
                lastListenedAt: item.lastListenedAt ?? .distantPast)
        }
        // Filter policy-ineligible items first, so a completed/capped recent
        // item cannot suppress a different qualified reading task.
        let qualified = candidates.compactMap { candidate -> (ResumeReminderCandidate, Date)? in
            guard let fire = policy.fireDate(now: now, candidate: candidate,
                sentForDoc: state.sentAt[candidate.id] ?? [], lastSentAny: state.lastSentAt) else { return nil }
            return (candidate, fire)
        }
        guard let (candidate, fire) = qualified.max(by: { $0.0.lastListenedAt < $1.0.lastListenedAt }) else { return }
        let accountBoundary = SystemActionStore.currentAccountBoundary

        let requestIdentifier = Self.requestPrefix + storageID + "." + candidate.id
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            Task { @MainActor in
                @MainActor func isCurrentCandidate() -> Bool {
                    guard self.appInBackground, self.scopeGeneration == expectedGeneration,
                          self.activeStorageID == storageID,
                          SystemActionStore.currentAccountBoundary == accountBoundary,
                          let current = ContentCatalog(history: .shared).item(id: candidate.id) else { return false }
                    return current.canContinue && current.availability.permitsReminder
                        && current.lastListenedAt == candidate.lastListenedAt
                }
                guard isCurrentCandidate() else { return }
                let content = UNMutableNotificationContent()
                content.title = AppLocalized("继续听")
                content.body = AppLocalized("上次还没听完，接着听？")
                content.sound = .default
                content.userInfo = ResumeReminderDeepLink.userInfo(documentID: candidate.id)
                let request = UNNotificationRequest(identifier: requestIdentifier, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(60, fire.timeIntervalSinceNow), repeats: false))
                // Only replace this feature's requests, leaving unrelated
                // system notifications untouched.
                let pending = await center.pendingNotificationRequests()
                center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.requestPrefix) })
                guard isCurrentCandidate() else { return }
                do {
                    try await center.add(request)
                    guard isCurrentCandidate() else {
                        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
                        return
                    }
                    self.markScheduled(docID: candidate.id, fireAt: fire,
                        daysSinceLastRead: max(0, Int(fire.timeIntervalSince(candidate.lastListenedAt) / 86_400)))
                } catch { return }
            }
        }
    }

    /// 调度成功即计入频控。提醒可能被系统或用户回前台取消，但按「已尝试」计数
    /// 是防骚扰的正确方向：宁可少提醒，不可用「没送达」当理由重复轰炸。
    private func markScheduled(docID: String, fireAt: Date, daysSinceLastRead: Int) {
        var sent = state.sentAt[docID] ?? []
        sent.append(fireAt)
        state.sentAt[docID] = Array(sent.suffix(policy.perDocLifetimeCap))
        state.lastSentAt = fireAt
        persist()
        ProductAnalytics.shared.trackResumeReminder(
            action: .scheduled,
            result: .success,
            permissionStatus: .authorized,
            trigger: "d1_continue",
            daysSinceLastRead: daysSinceLastRead
        )
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
        guard let key = scopedStateKey,
              let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func load() {
        guard let key = scopedStateKey,
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ResumeReminderState.self, from: data) else { return }
        state = decoded
    }

    private var scopedStateKey: String? {
        guard let activeStorageID else { return nil }
        #if DEBUG
        if activeStorageID == "debug-legacy" { return Self.stateKey }
        #endif
        return "\(Self.stateKey).account.\(activeStorageID)"
    }

    func invalidateCandidate(_ id: String) {
        guard let storageID = activeStorageID else { return }
        let identifier = Self.requestPrefix + storageID + "." + id
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func clearPendingNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.requestPrefix) })
        }
    }

    private static func isValidStorageID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func analyticsPermissionStatus(
        _ status: UNAuthorizationStatus
    ) -> AnalyticsNotificationPermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .unknown
        }
    }
}
