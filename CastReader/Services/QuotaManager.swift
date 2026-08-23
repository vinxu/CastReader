//
//  QuotaManager.swift
//  CastReader
//
//  免费额度本地计数（对齐扩展）。按本地日期午夜重置。Pro 不受限。
//  设计 fail-open：任何异常不阻断播放，只在额度真正耗尽时拦截。
//
//  两层策略（two_tier_v1，美区循环验证实验，见 docs/美区增长-书库有声书主轴落地方案.md §6/§12）：
//  首装赠额（一次性）+ 月度维持额，余额只由服务端签发；客户端把余额镜像进
//  Keychain（删装重来仍在，防刷双锚定之一），离线时用镜像继续扣减——**fail-close**：
//  服务端失联绝不变成无限额度。服务端不下发 quotaPolicy 时一切行为与 daily 完全一致。
//

import Foundation
import Combine

/// 免费额度策略。值与服务端 /api/pro/status 的 quotaPolicy 字段一致。
enum QuotaPolicy: String, Codable {
    /// 现行：每日午夜重置，本地计数 fail-open。
    case daily = "daily_v1"
    /// 实验：首装赠额 + 月度维持，服务端权威 + Keychain 镜像，fail-close。
    case twoTier = "two_tier_v1"
}

@MainActor
final class QuotaManager: ObservableObject {
    static let shared = QuotaManager()

    let dailyListenLimit: Double = 1200      // 20 分钟
    let dailyExplainLimit: Int = 3
    let graceCapSeconds: Double = 900        // “读完本篇”宽限硬上限 15 分钟

    @Published private(set) var listenSeconds: Double = 0
    @Published private(set) var explainCount: Int = 0

    // MARK: 两层策略状态

    /// 当前额度策略。只有服务端 /api/pro/status 能切到 twoTier；
    /// Keychain 持久化保证离线重启不掉回 daily 的无限日重置。
    @Published private(set) var policy: QuotaPolicy = .daily

    /// 两层余额镜像。真相在服务端；镜像用于离线显示与保守扣减。
    /// Keychain 存储（删装重装仍在），**镜像缺失时按 0 处理（fail-close）**。
    private struct TwoTierMirror: Codable {
        var listenRemaining: Double          // 总剩余（赠额 + 月度）
        var explainRemaining: Int
        var grantListenRemaining: Double     // 首装赠额层剩余
        var grantExplainRemaining: Int
        var grantListenExhaustedAt: Date?
        var grantExplainExhaustedAt: Date?
        var updatedAt: Date
    }

    private var twoTier: TwoTierMirror?

    // 服务端额度（可用时优先；nil 则用本地计数）
    @Published private(set) var serverListenRemaining: Double? = nil
    @Published private(set) var serverExplainRemaining: Int? = nil
    /// Prevents an older in-flight status response from undoing a locally
    /// observed server consumption during the same quota day.
    private var serverExplainProjectionCeiling: Int? = nil

    private let d = UserDefaults.standard
    private var day: String = ""
    private var activeStorageID: String?

    private init() {
        day = Self.localDay()
    }

    func activateAccountScope(storageID: String) {
        guard Self.isValidStorageID(storageID) else {
            deactivateAccountScope()
            return
        }
        guard activeStorageID != storageID else { return }
        GrowthLoopConversionCoordinator.shared.clearServerAssignment()
        activeStorageID = storageID
        loadLocalState()
        loadTwoTierState()
        clearServerProjection()
        rollIfNewDay()
    }

    func deactivateAccountScope() {
        GrowthLoopConversionCoordinator.shared.clearServerAssignment()
        activeStorageID = nil
        day = Self.localDay()
        listenSeconds = 0
        explainCount = 0
        policy = .daily
        twoTier = nil
        clearServerProjection()
    }

    #if DEBUG
    func activateLegacyTestingScope() {
        guard activeStorageID != "debug-legacy" else { return }
        activeStorageID = "debug-legacy"
        loadLocalState()
        clearServerProjection()
        rollIfNewDay()
    }
    #endif

    func rollIfNewDay() {
        guard activeStorageID != nil else { return }
        // 两层策略没有每日重置：赠额一次性、月度额由服务端在月初刷新
        // （applyServerStatus 回填），本地绝不自行补发。
        guard policy == .daily else { return }
        let today = Self.localDay()
        if today != day {
            day = today
            listenSeconds = 0
            explainCount = 0
            serverListenRemaining = nil
            serverExplainRemaining = nil
            serverExplainProjectionCeiling = nil
            persist()
        }
    }

    // MARK: 闸门查询

    func canStartListen(isPro: Bool) -> Bool {
        rollIfNewDay()
        return isPro || listenRemaining > 0
    }

    func canStartExplain(isPro: Bool) -> Bool {
        rollIfNewDay()
        return isPro || explainRemaining > 0
    }

    /// 剩余朗读秒数。two_tier：镜像值，缺失按 0（fail-close）；daily：服务端优先，否则本地。
    var listenRemaining: Double {
        if policy == .twoTier { return max(0, twoTier?.listenRemaining ?? 0) }
        return serverListenRemaining ?? max(0, dailyListenLimit - listenSeconds)
    }
    /// 剩余解读次数。two_tier：镜像值，缺失按 0（fail-close）；daily：服务端优先，否则本地。
    var explainRemaining: Int {
        if policy == .twoTier { return max(0, twoTier?.explainRemaining ?? 0) }
        return serverExplainRemaining ?? max(0, dailyExplainLimit - explainCount)
    }
    var listenMinutesUsed: Int { Int(listenSeconds / 60) }

    /// 用服务端 /api/pro/status 回填额度。
    func applyServerStatus(_ s: ProStatusDTO) {
        guard activeStorageID != nil else { return }
        GrowthLoopConversionCoordinator.shared.applyServerAssignment(
            s.growthConfig.map { GrowthProductAssignment(serverDTO: $0) }
        )
        if let rawPolicy = s.quotaPolicy, let parsed = QuotaPolicy(rawValue: rawPolicy) {
            policy = parsed
            persistPolicy()
        }
        if policy == .twoTier {
            applyTwoTierServerStatus(s)
            return
        }
        rollIfNewDay()
        if let r = s.listenRemaining { serverListenRemaining = Double(max(0, r)) }
        if let sec = s.listenSeconds { listenSeconds = Double(max(0, sec)) }
        if let fr = s.freeRemaining {
            let reported = max(0, fr)
            serverExplainRemaining = min(reported, serverExplainProjectionCeiling ?? reported)
        }
    }

    /// two_tier 语义：listenRemaining / freeRemaining = 总剩余（赠额 + 月度），
    /// grant* = 赠额层剩余。服务端值直接覆盖镜像（真相在服务端记账，
    /// 客户端消费经 listen-track / extract-plan 已同步上去）。
    private func applyTwoTierServerStatus(_ s: ProStatusDTO) {
        var mirror = twoTier ?? TwoTierMirror(
            listenRemaining: 0, explainRemaining: 0,
            grantListenRemaining: 0, grantExplainRemaining: 0,
            grantListenExhaustedAt: nil, grantExplainExhaustedAt: nil,
            updatedAt: Date()
        )
        if let r = s.listenRemaining { mirror.listenRemaining = Double(max(0, r)) }
        if let fr = s.freeRemaining { mirror.explainRemaining = max(0, fr) }
        if let g = s.grantListenRemaining {
            mirror.grantListenRemaining = Double(max(0, g))
            if g <= 0, mirror.grantListenExhaustedAt == nil {
                mirror.grantListenExhaustedAt = Date()
            }
        }
        if let g = s.grantExplainRemaining {
            mirror.grantExplainRemaining = max(0, g)
            if g <= 0, mirror.grantExplainExhaustedAt == nil {
                mirror.grantExplainExhaustedAt = Date()
            }
        }
        mirror.updatedAt = Date()
        twoTier = mirror
        persistTwoTierState()
        objectWillChange.send()
    }

    // MARK: 计数

    /// 累计已朗读秒数（仅正向），并上报服务端。
    func addListen(_ seconds: Double) {
        guard activeStorageID != nil, seconds > 0 else { return }
        rollIfNewDay()
        listenSeconds += seconds
        if policy == .twoTier, var mirror = twoTier {
            // 先扣赠额层、后扣月度层（对齐服务端扣减顺序）；赠额首次归零记录时刻，
            // 供 paywall trigger 区分 onboarding/monthly 耗尽。
            mirror.listenRemaining = max(0, mirror.listenRemaining - seconds)
            if mirror.grantListenRemaining > 0 {
                mirror.grantListenRemaining = max(0, mirror.grantListenRemaining - seconds)
                if mirror.grantListenRemaining <= 0, mirror.grantListenExhaustedAt == nil {
                    mirror.grantListenExhaustedAt = Date()
                }
            }
            mirror.updatedAt = Date()
            twoTier = mirror
            persistTwoTierState()
            objectWillChange.send()
        } else if let r = serverListenRemaining {
            serverListenRemaining = max(0, r - seconds)
        }
        persist()
        let secs = Int(seconds.rounded())
        Task { @MainActor in
            guard await AuthService.shared.ensureMobileSession() else { return }
            let outcome = await ProBackendService.shared.trackListen(seconds: secs)
            switch outcome {
            case .success(let response):
                applyListenTrackResponse(response)
            case .growthIdentityRequired:
                // The server could not bind this usage to the signed growth
                // assignment. Keep the already-decremented two-tier mirror
                // fail-closed, and refresh the authoritative status/identity.
                if policy == .twoTier {
                    await AuthService.shared.linkGrowthIdentityIfAuthenticated()
                    await ProManager.shared.refreshServer()
                }
            case .usageEventConflict, .unauthorized, .unavailable:
                // Do not retry a 409 or fall back to daily accounting. The
                // conservative local decrement remains until the next status.
                break
            }
        }
    }

    private func applyListenTrackResponse(_ response: ProListenTrackDTO) {
        if let rawPolicy = response.quotaPolicy,
           let parsed = QuotaPolicy(rawValue: rawPolicy) {
            policy = parsed
            persistPolicy()
        }
        guard policy == .twoTier else {
            serverListenRemaining = Double(max(0, response.remaining))
            return
        }
        var mirror = twoTier ?? TwoTierMirror(
            listenRemaining: 0,
            explainRemaining: 0,
            grantListenRemaining: 0,
            grantExplainRemaining: 0,
            grantListenExhaustedAt: nil,
            grantExplainExhaustedAt: nil,
            updatedAt: Date()
        )
        // Multiple paragraph-boundary consumption requests can complete out
        // of order. A consumption ACK may only keep or lower the optimistic
        // local mirror; only a fresh status generation is allowed to grant or
        // restore quota.
        mirror.listenRemaining = Self.monotonicConsumptionProjection(
            current: mirror.listenRemaining,
            reported: response.remaining
        )
        if let grantRemaining = response.grantListenRemaining {
            mirror.grantListenRemaining = Self.monotonicConsumptionProjection(
                current: mirror.grantListenRemaining,
                reported: grantRemaining
            )
            if grantRemaining <= 0, mirror.grantListenExhaustedAt == nil {
                mirror.grantListenExhaustedAt = Date()
            }
        }
        mirror.updatedAt = Date()
        twoTier = mirror
        persistTwoTierState()
        objectWillChange.send()
    }

    nonisolated static func monotonicConsumptionProjection(
        current: Double,
        reported: Int
    ) -> Double {
        min(max(0, current), Double(max(0, reported)))
    }

    /// 解读开始一次。服务端额度由 extract-plan 的 entitlement consume 负责；
    /// 本地只在服务端状态不可用时做 fallback 计数，避免一次会话双扣。
    /// two_tier：镜像永远来自服务端签发，这里不预扣（等 accepted 回调）。
    func noteExplainStarted(isPro: Bool) {
        guard activeStorageID != nil, !isPro else { return }
        rollIfNewDay()
        guard policy == .daily else { return }
        guard serverExplainRemaining == nil else { return }
        explainCount += 1
        persist()
    }

    /// 服务端已经接受本次 extract-plan 后，同步递减内存中的服务端额度投影。
    /// 只更新客户端缓存，不会再次请求服务端消费；失败请求不会调用这里。
    func noteExplainAcceptedByServer(isPro: Bool) {
        guard activeStorageID != nil, !isPro else { return }
        rollIfNewDay()
        if policy == .twoTier {
            guard var mirror = twoTier else { return }
            mirror.explainRemaining = max(0, mirror.explainRemaining - 1)
            if mirror.grantExplainRemaining > 0 {
                mirror.grantExplainRemaining = max(0, mirror.grantExplainRemaining - 1)
                if mirror.grantExplainRemaining <= 0, mirror.grantExplainExhaustedAt == nil {
                    mirror.grantExplainExhaustedAt = Date()
                }
            }
            mirror.updatedAt = Date()
            twoTier = mirror
            persistTwoTierState()
            objectWillChange.send()
            return
        }
        guard let remaining = serverExplainRemaining else { return }
        let projected = max(0, remaining - 1)
        serverExplainRemaining = projected
        serverExplainProjectionCeiling = min(projected, serverExplainProjectionCeiling ?? projected)
    }

    // MARK: 付费墙 trigger

    /// paywall_shown 的 trigger 归因。daily 策略保持既有值不变；two_tier 下
    /// 换成层级化 trigger：赠额层在近 7 天内归零 → `onboarding_exhausted`
    /// （价值峰值触点，循环验证 ④ 环判定门），否则 → `monthly_exhausted`。
    /// 非额度类 trigger（pro_speed / voice_clone …）原样透传。
    func paywallTrigger(replacing baseTrigger: String) -> String {
        guard policy == .twoTier else { return baseTrigger }
        let exhaustedAt: Date?
        switch baseTrigger {
        case "listen_quota": exhaustedAt = twoTier?.grantListenExhaustedAt
        case "explain_quota": exhaustedAt = twoTier?.grantExplainExhaustedAt
        default: return baseTrigger
        }
        if let exhaustedAt, Date().timeIntervalSince(exhaustedAt) < 7 * 86_400 {
            return "onboarding_exhausted"
        }
        return "monthly_exhausted"
    }

    // MARK: 持久化

    private func persist() {
        guard let keys = storageKeys else { return }
        d.set(day, forKey: keys.day)
        d.set(listenSeconds, forKey: keys.listen)
        d.set(explainCount, forKey: keys.explain)
    }

    private func loadLocalState() {
        guard let keys = storageKeys else {
            day = Self.localDay()
            listenSeconds = 0
            explainCount = 0
            return
        }
        day = d.string(forKey: keys.day) ?? Self.localDay()
        listenSeconds = d.double(forKey: keys.listen)
        explainCount = d.integer(forKey: keys.explain)
    }

    private func clearServerProjection() {
        serverListenRemaining = nil
        serverExplainRemaining = nil
        serverExplainProjectionCeiling = nil
    }

    // MARK: 两层策略持久化（Keychain：删装重装仍在，防刷锚定）

    private var twoTierPolicyKey: String? {
        activeStorageID.map { "quota.policy.v1.\($0)" }
    }
    private var twoTierMirrorKey: String? {
        activeStorageID.map { "quota.twotier.v1.\($0)" }
    }

    private func persistPolicy() {
        guard let key = twoTierPolicyKey else { return }
        KeychainStore.set(policy.rawValue, for: key)
    }

    private func persistTwoTierState() {
        guard let key = twoTierMirrorKey, let mirror = twoTier else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(mirror),
              let json = String(data: data, encoding: .utf8) else { return }
        KeychainStore.set(json, for: key)
    }

    private func loadTwoTierState() {
        policy = twoTierPolicyKey
            .flatMap { KeychainStore.get($0) }
            .flatMap(QuotaPolicy.init(rawValue:)) ?? .daily
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        twoTier = twoTierMirrorKey
            .flatMap { KeychainStore.get($0) }
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? decoder.decode(TwoTierMirror.self, from: $0) }
    }

    private struct StorageKeys {
        let day: String
        let listen: String
        let explain: String
    }

    private var storageKeys: StorageKeys? {
        guard let activeStorageID else { return nil }
        #if DEBUG
        if activeStorageID == "debug-legacy" {
            return StorageKeys(day: K.day, listen: K.listen, explain: K.explain)
        }
        #endif
        return StorageKeys(
            day: "\(K.day).account.\(activeStorageID)",
            listen: "\(K.listen).account.\(activeStorageID)",
            explain: "\(K.explain).account.\(activeStorageID)"
        )
    }

    static func localDay() -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    #if DEBUG
    /// 测试用：清空当日额度计数与服务端覆盖，回到干净起点（含两层策略状态）。
    func resetForTesting() {
        if activeStorageID == nil { activateLegacyTestingScope() }
        listenSeconds = 0
        explainCount = 0
        serverListenRemaining = nil
        serverExplainRemaining = nil
        serverExplainProjectionCeiling = nil
        policy = .daily
        twoTier = nil
        if let key = twoTierPolicyKey { KeychainStore.delete(key) }
        if let key = twoTierMirrorKey { KeychainStore.delete(key) }
        day = Self.localDay()
        persist()
    }
    #endif

    private enum K {
        static var day: String { ServiceRouting.current.isolatedStorageKey("quota_day") }
        static var listen: String {
            ServiceRouting.current.isolatedStorageKey("quota_listen_seconds")
        }
        static var explain: String {
            ServiceRouting.current.isolatedStorageKey("quota_explain_count")
        }
    }

    private static func isValidStorageID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
