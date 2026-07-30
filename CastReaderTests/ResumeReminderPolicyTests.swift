//
//  ResumeReminderPolicyTests.swift
//  CastReaderTests
//
//  「继续听」召回策略的防骚扰契约。策略层是纯函数，全部确定性覆盖。
//

import XCTest
@testable import CastReader

final class ResumeReminderPolicyTests: XCTestCase {

    private let policy = ResumeReminderPolicy()
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        listened: Double = 600,
        lastListenedAgo: TimeInterval = 1_800
    ) -> ResumeReminderCandidate {
        ResumeReminderCandidate(
            id: "doc-1", title: "Walden",
            listenedSeconds: listened,
            lastListenedAt: base.addingTimeInterval(-lastListenedAgo)
        )
    }

    // MARK: 够格条件

    func testRequiresMinimumRealListening() {
        XCTAssertNil(
            policy.fireDate(now: base, candidate: candidate(listened: 59), sentForDoc: [], lastSentAny: nil),
            "不足 60s 真实收听的内容不得提醒"
        )
        XCTAssertNotNil(
            policy.fireDate(now: base, candidate: candidate(listened: 60), sentForDoc: [], lastSentAny: nil)
        )
    }

    func testStaleInterruptionIsNotReminded() {
        let stale = candidate(lastListenedAgo: 73 * 3600)
        XCTAssertNil(
            policy.fireDate(now: base, candidate: stale, sentForDoc: [], lastSentAny: nil),
            "超过 72h 的中断意图已冷，不再打扰"
        )
    }

    // MARK: 触发时刻

    func testFiresTwentyFourHoursAfterLastListen() {
        let c = candidate(lastListenedAgo: 1_800)
        let fire = policy.fireDate(now: base, candidate: c, sentForDoc: [], lastSentAny: nil)
        XCTAssertEqual(
            fire, c.lastListenedAt.addingTimeInterval(24 * 3600),
            "正常路径锚定「最后收听 +24h」"
        )
    }

    func testMinimumLeadTimePreventsImmediateFiring() {
        // 听完 30h 后才进后台：+24h 已过，触发点必须离现在至少 6h，不能刚锁屏就响。
        let c = candidate(lastListenedAgo: 30 * 3600)
        let fire = policy.fireDate(now: base, candidate: c, sentForDoc: [], lastSentAny: nil)
        XCTAssertEqual(fire, base.addingTimeInterval(6 * 3600))
    }

    // MARK: 频控

    func testPerDocLifetimeCapIsTwo() {
        let sent = [base.addingTimeInterval(-30 * 24 * 3600), base.addingTimeInterval(-15 * 24 * 3600)]
        XCTAssertNil(
            policy.fireDate(now: base, candidate: candidate(), sentForDoc: sent, lastSentAny: nil),
            "单内容一生最多 2 次"
        )
    }

    func testPerDocCooldownIsSevenDays() {
        let recent = [base.addingTimeInterval(-3 * 24 * 3600)]
        XCTAssertNil(
            policy.fireDate(now: base, candidate: candidate(), sentForDoc: recent, lastSentAny: nil),
            "同一内容 7 天内不重复提醒"
        )
        let old = [base.addingTimeInterval(-8 * 24 * 3600)]
        XCTAssertNotNil(
            policy.fireDate(now: base, candidate: candidate(), sentForDoc: old, lastSentAny: nil)
        )
    }

    func testGlobalIntervalDefersInsteadOfDropping() {
        // 常规锚点（最后收听 20h 前 → +24h = 4h 后，抬到最小提前量 6h）早于全局频控点时，
        // 顺延到距上一条 20h，而不是直接放弃。
        let lastAny = base.addingTimeInterval(-2 * 3600)
        let c = candidate(lastListenedAgo: 20 * 3600)
        let fire = policy.fireDate(now: base, candidate: c, sentForDoc: [], lastSentAny: lastAny)
        XCTAssertEqual(fire, lastAny.addingTimeInterval(20 * 3600))
    }

    func testGlobalIntervalDoesNotPullFiringEarlier() {
        // 频控只会推迟、不会提前：常规锚点已晚于频控点时保持常规锚点。
        let lastAny = base.addingTimeInterval(-2 * 3600)
        let c = candidate(lastListenedAgo: 1_800)
        let fire = policy.fireDate(now: base, candidate: c, sentForDoc: [], lastSentAny: lastAny)
        XCTAssertEqual(fire, c.lastListenedAt.addingTimeInterval(24 * 3600))
    }

    func testDeferredFireStillBoundByFreshness() {
        // 顺延后超出「新鲜窗 + 延迟」总预算 → 放弃，不发一条过时提醒。
        let c = candidate(lastListenedAgo: 60 * 3600)
        let lastAny = base.addingTimeInterval(50 * 3600)   // 未来已有排期（极端排队）
        XCTAssertNil(policy.fireDate(now: base, candidate: c, sentForDoc: [], lastSentAny: lastAny))
    }

    // MARK: 候选挑选与 delta 口径

    func testPicksMostRecentlyListenedCandidate() {
        let older = ResumeReminderCandidate(
            id: "a", title: "A", listenedSeconds: 900,
            lastListenedAt: base.addingTimeInterval(-7_200)
        )
        let newer = ResumeReminderCandidate(
            id: "b", title: "B", listenedSeconds: 90,
            lastListenedAt: base.addingTimeInterval(-600)
        )
        XCTAssertEqual(ResumeReminderPolicy.pick([older, newer])?.id, "b", "意图最新的优先，与听了多久无关")
        XCTAssertNil(ResumeReminderPolicy.pick([]))
    }

    func testTrustedDeltaCapMatchesSiblingPipelines() {
        // 与评分资格（AppReviewPromptManager）和书库引导激活共用同一 tick 口径：
        // 单次 delta > 2.01s 视为拖动/跳变。三条管线的口径必须一致，否则同一动作会被不同功能各自解读。
        XCTAssertEqual(ResumeReminderPolicy.maxTrustedDelta, 2.01, accuracy: 0.0001)
    }

    // MARK: 权限时机

    func testPermissionPromptRequiresRealEngagement() {
        XCTAssertEqual(policy.permissionPromptThreshold, 180, "首启不弹权限：累计 3 分钟真实收听后才请求")
    }
}
