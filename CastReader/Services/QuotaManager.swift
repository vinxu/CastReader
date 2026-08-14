//
//  QuotaManager.swift
//  CastReader
//
//  免费额度本地计数（对齐扩展）。按本地日期午夜重置。Pro 不受限。
//  设计 fail-open：任何异常不阻断播放，只在额度真正耗尽时拦截。
//

import Foundation
import Combine

@MainActor
final class QuotaManager: ObservableObject {
    static let shared = QuotaManager()

    let dailyListenLimit: Double = 1200      // 20 分钟
    let dailyExplainLimit: Int = 3
    let graceCapSeconds: Double = 900        // “读完本篇”宽限硬上限 15 分钟

    @Published private(set) var listenSeconds: Double = 0
    @Published private(set) var explainCount: Int = 0

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
        activeStorageID = storageID
        loadLocalState()
        clearServerProjection()
        rollIfNewDay()
    }

    func deactivateAccountScope() {
        activeStorageID = nil
        day = Self.localDay()
        listenSeconds = 0
        explainCount = 0
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

    /// 剩余朗读秒数：服务端优先，否则本地。
    var listenRemaining: Double { serverListenRemaining ?? max(0, dailyListenLimit - listenSeconds) }
    /// 剩余解读次数：服务端优先，否则本地。
    var explainRemaining: Int { serverExplainRemaining ?? max(0, dailyExplainLimit - explainCount) }
    var listenMinutesUsed: Int { Int(listenSeconds / 60) }

    /// 用服务端 /api/pro/status 回填额度。
    func applyServerStatus(_ s: ProStatusDTO) {
        guard activeStorageID != nil else { return }
        rollIfNewDay()
        if let r = s.listenRemaining { serverListenRemaining = Double(max(0, r)) }
        if let sec = s.listenSeconds { listenSeconds = Double(max(0, sec)) }
        if let fr = s.freeRemaining {
            let reported = max(0, fr)
            serverExplainRemaining = min(reported, serverExplainProjectionCeiling ?? reported)
        }
    }

    // MARK: 计数

    /// 累计已朗读秒数（仅正向），并上报服务端。
    func addListen(_ seconds: Double) {
        guard activeStorageID != nil, seconds > 0 else { return }
        rollIfNewDay()
        listenSeconds += seconds
        if let r = serverListenRemaining { serverListenRemaining = max(0, r - seconds) }
        persist()
        let secs = Int(seconds.rounded())
        Task { @MainActor in
            guard await AuthService.shared.ensureMobileSession() else { return }
            await ProBackendService.shared.trackListen(seconds: secs)
        }
    }

    /// 解读开始一次。服务端额度由 extract-plan 的 entitlement consume 负责；
    /// 本地只在服务端状态不可用时做 fallback 计数，避免一次会话双扣。
    func noteExplainStarted(isPro: Bool) {
        guard activeStorageID != nil, !isPro else { return }
        rollIfNewDay()
        guard serverExplainRemaining == nil else { return }
        explainCount += 1
        persist()
    }

    /// 服务端已经接受本次 extract-plan 后，同步递减内存中的服务端额度投影。
    /// 只更新客户端缓存，不会再次请求服务端消费；失败请求不会调用这里。
    func noteExplainAcceptedByServer(isPro: Bool) {
        guard activeStorageID != nil else { return }
        rollIfNewDay()
        guard !isPro, let remaining = serverExplainRemaining else { return }
        let projected = max(0, remaining - 1)
        serverExplainRemaining = projected
        serverExplainProjectionCeiling = min(projected, serverExplainProjectionCeiling ?? projected)
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
    /// 测试用：清空当日额度计数与服务端覆盖，回到干净起点。
    func resetForTesting() {
        if activeStorageID == nil { activateLegacyTestingScope() }
        listenSeconds = 0
        explainCount = 0
        serverListenRemaining = nil
        serverExplainRemaining = nil
        serverExplainProjectionCeiling = nil
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
