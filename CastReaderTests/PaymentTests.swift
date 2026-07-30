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
            AuthService.shared.signOut()
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
            AuthService.shared.signOut()
            ProManager.shared.debugForcePro = true       // 恢复开发期解锁
            QuotaManager.shared.resetForTesting()
        }
    }

    @MainActor
    private func signInPurchaseAccount() {
        AuthService.shared.applyAccount(UserAccount(
            id: "storekit-test-provider-id",
            email: "storekit-test@example.com",
            name: "StoreKit Test",
            pictureURL: nil,
            provider: "google",
            backendUserId: "storekit-test-backend-id"
        ))
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
    func testPurchase_requiresEmail() async throws {
        let products = try await Product.products(for: [ProManager.monthlyID])
        let product = try XCTUnwrap(products.first, "未加载月度产品")
        XCTAssertFalse(AuthService.shared.hasEmailAccount, "测试起点应为未登录邮箱")

        let unlocked = await ProManager.shared.purchase(product)

        XCTAssertFalse(unlocked, "未登录邮箱时不允许发起新购买")
        XCTAssertFalse(ProManager.shared.storeKitPro, "购买被拦截时不应产生本地 StoreKit 权益")
        XCTAssertFalse(ProManager.shared.isPro, "未登录且未购买时不是 Pro")
    }

    @MainActor
    func testPurchase_unlocksPro() async throws {
        signInPurchaseAccount()
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
        signInPurchaseAccount()
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
        signInPurchaseAccount()
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

    // MARK: 8. 首购免费试用

    func testBothProductsOfferSevenDayFreeTrial() async throws {
        let products = try await Product.products(for: ProManager.productIDs)
        XCTAssertEqual(products.count, 2)
        for product in products {
            let offer = try XCTUnwrap(product.subscription?.introductoryOffer, "\(product.id) 缺少首购优惠")
            XCTAssertEqual(offer.paymentMode, .freeTrial, "\(product.id) 应为免费试用而非首期折扣")
            XCTAssertEqual(ProManager.freeTrialDays(for: product), 7, "\(product.id) 应为 7 天试用")
        }
    }

    /// 试用资格是每个 Apple ID 在订阅组内一次性的。资格用掉后仍显示「免费试用」属于 3.1.2
    /// 误导性订阅文案，所以锁死门控：产品即便配置了 offer，只要不在资格集合里就不得承诺试用。
    ///
    /// 「购买 → isEligibleForIntroOffer 翻 false」是 Apple 的行为，不在这里复测
    /// （真实购买弹窗会挂起测试运行、SKTestSession.buyProduct 在本宿主下抛 notEntitled）；
    /// 这里用注入的资格集合确定性覆盖我们自己的分支。
    @MainActor
    func testFreeTrialGateRequiresBothOfferAndEligibility() async throws {
        session.clearTransactions()
        let pro = ProManager.shared
        await pro.loadProducts()
        let yearly = try XCTUnwrap(pro.yearly)
        XCTAssertNotNil(yearly.subscription?.introductoryOffer, "本地配置应带 7 天试用 offer")

        pro.setIntroOfferEligibilityForTesting([ProManager.yearlyID, ProManager.monthlyID])
        XCTAssertTrue(pro.showsFreeTrial(for: yearly), "有 offer 且有资格 → 展示试用")

        pro.setIntroOfferEligibilityForTesting([])
        XCTAssertFalse(pro.showsFreeTrial(for: yearly), "资格已消耗 → 不得继续承诺试用")

        // 真实刷新（未购买的干净会话）应恢复资格——顺带覆盖 refreshIntroOfferEligibility 主路径。
        await pro.refreshIntroOfferEligibility()
        XCTAssertTrue(pro.showsFreeTrial(for: yearly), "干净会话刷新后应重新可试用")
    }

    /// 没有试用资格时，付费入口必须退回纯价格文案，不能出现空的试用天数。
    ///
    /// 断言刻意做成语言无关的：测试宿主的 locale 不固定，写死任何一种语言的字面值都会假失败。
    /// 这里验的是分支选择和占位符填充是否正确，而不是某种语言的译文。
    func testHomeCardCopySwitchesBetweenTrialAndPrice() {
        let trialTitle = HomeProTrialCopy.primaryTitle(trialDays: 7, annualDisplayPrice: "$34.99")
        let priceTitle = HomeProTrialCopy.primaryTitle(trialDays: nil, annualDisplayPrice: "$34.99")
        XCTAssertTrue(trialTitle.contains("7"), "有试用资格时主按钮必须写明天数：\(trialTitle)")
        XCTAssertFalse(trialTitle.contains("$34.99"), "有试用资格时主按钮不该先喊价格：\(trialTitle)")
        XCTAssertTrue(priceTitle.contains("$34.99"), "无试用资格时主按钮必须给价格：\(priceTitle)")
        XCTAssertNotEqual(trialTitle, priceTitle)

        // Apple 3.1.2：有试用就必须同时讲清试用时长与到期价格。
        let trialNotice = HomeProTrialCopy.renewalNotice(trialDays: 7, annualDisplayPrice: "$34.99")
        XCTAssertTrue(trialNotice.contains("7"), "续订说明缺试用时长：\(trialNotice)")
        XCTAssertTrue(trialNotice.contains("$34.99"), "续订说明缺到期价格：\(trialNotice)")

        let plainNotice = HomeProTrialCopy.renewalNotice(trialDays: nil, annualDisplayPrice: "$34.99")
        XCTAssertFalse(plainNotice.contains("7"), "没有试用资格却出现试用天数：\(plainNotice)")
        XCTAssertEqual(
            HomeProTrialCopy.renewalNotice(trialDays: 7, annualDisplayPrice: nil),
            plainNotice,
            "拿不到价格时不能只承诺试用而不说到期价格"
        )
    }
}
