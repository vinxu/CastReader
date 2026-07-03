//
//  PaymentTests.swift
//  CastReaderTests
//
//  StoreKitTest 端到端付费流程自检（加载 Configuration.storekit，禁用弹窗自动成交）：
//  付费前限制 → 购买解锁 → 付费后无限 → 扣费 → 恢复 → 过期回落。
//  关键：关闭 ProManager.debugForcePro，使 isPro 走真实内购权益（否则 DEBUG 恒 true，测试无意义）。
//

import XCTest
import StoreKit
import StoreKitTest
@testable import CastReader

final class PaymentTests: XCTestCase {

    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Configuration")
        session.disableDialogs = true     // 购买不弹确认框，自动成交
        session.clearTransactions()
        await MainActor.run {
            ProManager.shared.debugForcePro = false      // 关模拟解锁 → isPro 走真实权益
            ProManager.shared.clearServerEntitlement()   // 隔离 serverPro，避免 refresh 网络维度干扰断言
            QuotaManager.shared.resetForTesting()
        }
        await ProManager.shared.refreshEntitlements()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
        await MainActor.run {
            ProManager.shared.debugForcePro = true       // 恢复开发期解锁
            QuotaManager.shared.resetForTesting()
        }
    }

    // MARK: 0. 服务端 Pro 状态响应

    func testProStatusDecodesWrappedServerResponse() throws {
        let json = """
        {
          "code": 0,
          "message": "ok",
          "data": {
            "pro": true,
            "plan": "yearly",
            "account": {
              "name": "Reader",
              "email": "reader@example.com",
              "image": "https://example.com/avatar.png"
            },
            "freeRemaining": 3,
            "freeMax": 3,
            "listenSeconds": 42,
            "listenLimit": 1200,
            "listenRemaining": 1158
          }
        }
        """.data(using: .utf8)!

        let status = try ProStatusDTO.decodeServerResponse(from: json)

        XCTAssertTrue(status.pro)
        XCTAssertEqual(status.plan, "yearly")
        XCTAssertEqual(status.account?.email, "reader@example.com")
        XCTAssertEqual(status.listenRemaining, 1158)
    }

    func testProStatusStillDecodesDirectResponse() throws {
        let json = """
        {
          "pro": false,
          "plan": null,
          "account": null,
          "freeRemaining": 2,
          "freeMax": 3,
          "listenSeconds": 60,
          "listenLimit": 1200,
          "listenRemaining": 1140
        }
        """.data(using: .utf8)!

        let status = try ProStatusDTO.decodeServerResponse(from: json)

        XCTAssertFalse(status.pro)
        XCTAssertEqual(status.freeRemaining, 2)
        XCTAssertEqual(status.listenSeconds, 60)
    }

    // MARK: 1. 产品加载

    @MainActor
    func testProductsLoad() async throws {
        let products = try await Product.products(for: ProManager.productIDs)
        XCTAssertEqual(products.count, 2, "应加载月度+年度两个产品")
        XCTAssertTrue(products.contains { $0.id == ProManager.monthlyID })
        XCTAssertTrue(products.contains { $0.id == ProManager.yearlyID })
    }

    // MARK: 2. 付费前限制

    @MainActor
    func testBeforePurchase_notPro() async throws {
        session.clearTransactions()
        await ProManager.shared.refreshEntitlements()
        XCTAssertFalse(ProManager.shared.storeKitPro, "未购买 → storeKitPro=false")
        XCTAssertFalse(ProManager.shared.isPro, "未购买且关模拟解锁 → isPro=false")
    }

    @MainActor
    func testBeforePurchase_listenQuotaGate() async throws {
        let q = QuotaManager.shared
        q.resetForTesting()
        XCTAssertTrue(q.canStartListen(isPro: false), "有额度 → 可朗读")
        q.addListen(q.dailyListenLimit + 10)               // 用满 20min
        XCTAssertEqual(q.listenRemaining, 0, accuracy: 0.5)
        XCTAssertFalse(q.canStartListen(isPro: false), "免费额度耗尽 → 不可朗读")
    }

    @MainActor
    func testBeforePurchase_explainQuotaGate() async throws {
        let q = QuotaManager.shared
        q.resetForTesting()
        XCTAssertTrue(q.canStartExplain(isPro: false))
        for _ in 0..<q.dailyExplainLimit { q.noteExplainStarted(isPro: false) }
        XCTAssertEqual(q.explainRemaining, 0)
        XCTAssertFalse(q.canStartExplain(isPro: false), "免费解读次数耗尽 → 不可解读")
    }

    // MARK: 3. 购买解锁 Pro

    @MainActor
    func testPurchase_unlocksPro() async throws {
        let products = try await Product.products(for: [ProManager.monthlyID])
        let product = try XCTUnwrap(products.first, "未加载月度产品")
        let unlocked = await ProManager.shared.purchase(product)
        XCTAssertTrue(unlocked, "购买后 ProManager.purchase 应返回已解锁")
        XCTAssertTrue(ProManager.shared.storeKitPro, "购买后 storeKitPro=true")
        XCTAssertTrue(ProManager.shared.isPro, "购买后 isPro=true")
    }

    // MARK: 4. 付费后无限（额度闸门解除）

    @MainActor
    func testPro_bypassesQuota() async throws {
        let q = QuotaManager.shared
        q.resetForTesting()
        q.addListen(q.dailyListenLimit + 9999)             // 远超免费额度
        for _ in 0..<(q.dailyExplainLimit + 5) { q.noteExplainStarted(isPro: false) }
        XCTAssertFalse(q.canStartListen(isPro: false), "免费身份仍受限")
        XCTAssertTrue(q.canStartListen(isPro: true), "Pro 无视朗读额度")
        XCTAssertTrue(q.canStartExplain(isPro: true), "Pro 无视解读次数")
    }

    // MARK: 5. 扣费累加

    @MainActor
    func testListenAccounting() async throws {
        let q = QuotaManager.shared
        q.resetForTesting()
        let before = q.listenRemaining
        q.addListen(60)
        XCTAssertEqual(q.listenRemaining, before - 60, accuracy: 0.5, "朗读 60s → 剩余 -60")
        XCTAssertEqual(q.listenMinutesUsed, 1)
        q.addListen(-5)                                    // 负值不计
        XCTAssertEqual(q.listenMinutesUsed, 1, "负秒数不累加")
    }

    // MARK: 6. 恢复购买

    @MainActor
    func testRestorePurchase() async throws {
        let products = try await Product.products(for: [ProManager.yearlyID])
        let product = try XCTUnwrap(products.first)
        _ = await ProManager.shared.purchase(product)
        XCTAssertTrue(ProManager.shared.storeKitPro, "购买年度后应 Pro")
        await ProManager.shared.restore()                  // AppStore.sync + refresh
        XCTAssertTrue(ProManager.shared.storeKitPro, "恢复后仍 Pro")
    }

    // MARK: 7. 订阅过期 → 回落免费

    @MainActor
    func testExpiry_revertsToFree() async throws {
        let products = try await Product.products(for: [ProManager.monthlyID])
        let product = try XCTUnwrap(products.first)
        _ = await ProManager.shared.purchase(product)
        XCTAssertTrue(ProManager.shared.storeKitPro, "购买后 Pro")
        // 订阅失效（过期/退款后权益从 currentEntitlements 移除）→ clearTransactions 确定性模拟，
        // 验证 refreshEntitlements 在无有效权益时把 storeKitPro 归 false（不依赖 expireSubscription 的续订日时序）。
        session.clearTransactions()
        await MainActor.run { ProManager.shared.clearServerEntitlement() }
        await ProManager.shared.refreshEntitlements()
        XCTAssertFalse(ProManager.shared.storeKitPro, "订阅失效 → storeKitPro=false")
        XCTAssertFalse(ProManager.shared.isPro, "失效后 isPro=false（已关模拟解锁）")
    }
}
