//
//  AdAttributionService.swift
//  CastReader
//
//  Apple Ads 归因采集：首启读取 AdServices attributionToken，作为 ad_attribution
//  事件上报；token 由服务端调用 Apple 归因 API（api-adservices.apple.com）换取
//  campaign/keyword。投放的词级 CAC 读数（循环验证协议第⑤环）依赖此事件。
//
//  attributionToken() 与 ATT 无关，不弹任何权限；模拟器上会抛错。
//

import Foundation
import AdServices

/// 每台设备一生只上报一次：成功拿到 token（或确认不可用）后落盘封存。
/// 真机偶发失败留给下次启动重试，超过尝试上限则记 unavailable 封存——
/// 让「可归因装机占比」在漏斗里可见，而不是静默缺数。
@MainActor
final class AdAttributionService {
    static let shared = AdAttributionService()

    private static let reportedKey = "ad_attribution.reported.v1"
    private static let attemptKey = "ad_attribution.attempts.v1"
    private static let maxAttempts = 5

    private let defaults = UserDefaults.standard

    private init() {}

    func reportOnceIfNeeded() {
        guard !defaults.bool(forKey: Self.reportedKey) else { return }
        let attempts = defaults.integer(forKey: Self.attemptKey) + 1
        guard attempts <= Self.maxAttempts else {
            markReported(result: "unavailable", token: nil, attempts: attempts - 1)
            return
        }
        defaults.set(attempts, forKey: Self.attemptKey)

        // 同步 API 但涉及磁盘/系统服务，不放在主线程首帧路径上。
        Task.detached(priority: .utility) {
            let token = try? AAAttribution.attributionToken()
            await MainActor.run {
                guard let token, !token.isEmpty else {
                    // 模拟器或系统服务暂不可用：本次不封存，下次启动再试。
                    return
                }
                self.markReported(result: "token", token: token, attempts: attempts)
            }
        }
    }

    private func markReported(result: String, token: String?, attempts: Int) {
        defaults.set(true, forKey: Self.reportedKey)
        ProductAnalytics.shared.adAttribution(
            result: result,
            token: token,
            attemptCount: attempts
        )
    }
}
