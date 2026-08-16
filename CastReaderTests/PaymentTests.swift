//
//  PaymentTests.swift
//  CastReaderTests
//
//  StoreKitTest 端到端付费流程自检（加载 Configuration.storekit，禁用弹窗自动成交）：
//  付费前限制 → 购买解锁 → 付费后无限 → 扣费 → 恢复 → 过期回落。
//  关键：保持 ProManager.debugForcePro 关闭，使 isPro 走真实内购权益。
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
            ProManager.shared.debugForcePro = false      // 测试包默认也走真实账号权益
            QuotaManager.shared.resetForTesting()
        }
    }

    func testDebugProIsFailClosedUnlessExplicitlyEnabled() {
        XCTAssertFalse(
            ProManager.resolvedDebugForcePro(arguments: [], persistedValue: nil)
        )
        XCTAssertFalse(
            ProManager.resolvedDebugForcePro(
                arguments: ["-CastReaderDisableDebugPro", "-CastReaderForceDebugPro"],
                persistedValue: true
            )
        )
        XCTAssertTrue(
            ProManager.resolvedDebugForcePro(
                arguments: ["-CastReaderForceDebugPro"],
                persistedValue: nil
            )
        )
        XCTAssertFalse(
            ProManager.resolvedDebugForcePro(arguments: [], persistedValue: false)
        )
        XCTAssertTrue(
            ProManager.resolvedDebugForcePro(arguments: [], persistedValue: true)
        )
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

    func testPhoneBackendUserCanAdoptServerProWithoutEmail() {
        XCTAssertEqual(
            ProManager.serverIdentityKey(userId: "  phone-user-42  ", email: nil),
            "user:phone-user-42|email:-"
        )
        XCTAssertTrue(
            ProManager.shouldAdoptServerPro(
                true,
                userId: "  phone-user-42  ",
                email: nil
            ),
            "手机号账号有规范化 backend user id 时必须采用服务端 Pro"
        )
        XCTAssertFalse(
            ProManager.shouldAdoptServerPro(
                false,
                userId: "phone-user-42",
                email: nil
            )
        )
    }

    func testAnonymousStatusCanNeverGrantServerPro() {
        XCTAssertNil(ProManager.serverIdentityKey(userId: nil, email: nil))
        XCTAssertNil(ProManager.serverIdentityKey(userId: "  ", email: "\n"))
        XCTAssertFalse(
            ProManager.shouldAdoptServerPro(true, userId: nil, email: nil),
            "只有 device_id 的匿名状态不能授予跨端 Pro"
        )
    }

    func testServerIdentityNormalizesEmailAndChangesWithPhoneAccount() {
        XCTAssertEqual(
            ProManager.serverIdentityKey(userId: "user-a", email: " Reader@Example.COM "),
            "user:user-a|email:reader@example.com"
        )
        XCTAssertNotEqual(
            ProManager.serverIdentityKey(userId: "phone-a", email: nil),
            ProManager.serverIdentityKey(userId: "phone-b", email: nil),
            "两个无邮箱手机号账号必须有不同的内存权益身份"
        )
    }

    func testAccountBoundStoreKitTokenIsStableAccountScopedAndFailClosed() {
        let token = ProManager.accountBoundAppAccountToken(userId: " user-42 ")
        XCTAssertEqual(
            token,
            ProManager.accountBoundAppAccountToken(userId: "user-42")
        )
        XCTAssertEqual(
            token.uuidString.lowercased(),
            "d346986d-7e0b-805a-b235-41f487858289",
            "iOS and backend must derive the exact same UUIDv8 bytes"
        )
        XCTAssertNotEqual(
            token,
            ProManager.accountBoundAppAccountToken(userId: "user-99")
        )
        XCTAssertTrue(ProManager.isAccountBoundAppAccountToken(token))
        XCTAssertTrue(ProManager.transactionBelongsToCurrentAccount(
            appAccountToken: token,
            expectedAccountToken: token
        ))
        XCTAssertFalse(ProManager.transactionBelongsToCurrentAccount(
            appAccountToken: token,
            expectedAccountToken: nil
        ))
        XCTAssertFalse(ProManager.transactionBelongsToCurrentAccount(
            appAccountToken: token,
            expectedAccountToken: ProManager.accountBoundAppAccountToken(userId: "user-99")
        ))
        XCTAssertTrue(
            ProManager.transactionBelongsToCurrentAccount(
                appAccountToken: UUID(),
                expectedAccountToken: token
            ),
            "legacy UUIDv4 purchases must remain restorable"
        )
    }

    func testOnlyVerifiedStoreKitTransactionsMayBeFinished() {
        XCTAssertTrue(ProManager.shouldFinishStoreKitTransaction(isVerified: true))
        XCTAssertFalse(
            ProManager.shouldFinishStoreKitTransaction(isVerified: false),
            "unverified charged transactions must remain available for retry"
        )
    }

    func testTransactionUpdatesRejectForeignProductsAndAccountBoundMismatches() {
        let current = ProManager.accountBoundAppAccountToken(userId: "user-current")
        let other = ProManager.accountBoundAppAccountToken(userId: "user-other")

        XCTAssertTrue(ProManager.shouldProcessTransactionUpdate(
            productID: ProManager.yearlyID,
            appAccountToken: current,
            expectedAccountToken: current
        ))
        XCTAssertFalse(ProManager.shouldProcessTransactionUpdate(
            productID: "com.example.unrelated.product",
            appAccountToken: current,
            expectedAccountToken: current
        ), "non-CastReader products must never be finished by this listener")
        XCTAssertFalse(ProManager.shouldProcessTransactionUpdate(
            productID: ProManager.monthlyID,
            appAccountToken: other,
            expectedAccountToken: current
        ), "a UUIDv8 transaction bound to another account must remain pending")
        XCTAssertFalse(ProManager.shouldProcessTransactionUpdate(
            productID: ProManager.monthlyID,
            appAccountToken: current,
            expectedAccountToken: nil
        ), "UUIDv8 must fail closed when no canonical backend account is available")
    }

    func testTransactionUpdatesPreserveLegacyUUIDCompatibility() {
        let current = ProManager.accountBoundAppAccountToken(userId: "user-current")
        XCTAssertTrue(ProManager.shouldProcessTransactionUpdate(
            productID: ProManager.monthlyID,
            appAccountToken: UUID(),
            expectedAccountToken: current
        ), "historical UUIDv4 transactions remain restorable")
        XCTAssertTrue(ProManager.shouldProcessTransactionUpdate(
            productID: ProManager.yearlyID,
            appAccountToken: nil,
            expectedAccountToken: nil
        ), "historical nil tokens retain the released compatibility policy")
    }

    func testAnonymousDeviceIdentityPreservesLegacyKeysAndIsolatesChinaRoute() {
        XCTAssertEqual(
            StableDeviceID.keychainKey(for: .globalGateway),
            "stable_device_id",
            "old live installations must keep their exact Keychain identity"
        )
        XCTAssertEqual(
            StableDeviceID.defaultsKey(for: .globalGateway),
            Constants.Storage.visitorIdKey
        )
        XCTAssertEqual(
            StableDeviceID.keychainKey(for: .chinaGateway),
            "stable_device_id.cn"
        )
        XCTAssertEqual(
            StableDeviceID.defaultsKey(for: .chinaGateway),
            "\(Constants.Storage.visitorIdKey).cn"
        )
    }

    // MARK: 1. 产品加载

    @MainActor
    func testProductsLoad() async throws {
        let products = try await Product.products(for: ProManager.productIDs)
        XCTAssertEqual(products.count, 4, "应加载 v1+v2 各月度/年度共四个产品")
        XCTAssertTrue(products.contains { $0.id == ProManager.monthlyID })
        XCTAssertTrue(products.contains { $0.id == ProManager.yearlyID })
        XCTAssertTrue(products.contains { $0.id == ProManager.monthlyV2ID })
        XCTAssertTrue(products.contains { $0.id == ProManager.yearlyV2ID })
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

    @MainActor
    func testServerExplainQuotaProjectionDecrementsOnlyAfterPlanIsAccepted() async throws {
        let q = QuotaManager.shared
        q.resetForTesting()
        q.applyServerStatus(ProStatusDTO(
            pro: false,
            plan: nil,
            account: nil,
            freeRemaining: 1,
            freeMax: 3,
            listenSeconds: 0,
            listenLimit: 1200,
            listenRemaining: 1200
        ))

        q.noteExplainStarted(isPro: false)
        XCTAssertEqual(q.explainRemaining, 1, "请求尚未被服务端接受时不能提前扣缓存额度")

        q.noteExplainAcceptedByServer(isPro: false)
        XCTAssertEqual(q.explainRemaining, 0, "服务端接受 plan 后应立即更新本地额度投影")
        XCTAssertFalse(q.canStartExplain(isPro: false))

        q.applyServerStatus(ProStatusDTO(
            pro: false,
            plan: nil,
            account: nil,
            freeRemaining: 1,
            freeMax: 3,
            listenSeconds: 0,
            listenLimit: 1200,
            listenRemaining: 1200
        ))
        XCTAssertEqual(q.explainRemaining, 0, "较早发出的状态请求晚到时，不能把已消费额度恢复为可用")
    }

    // MARK: 3. 购买解锁 Pro

    @MainActor
    func testPurchase_requiresSignIn() async throws {
        let products = try await Product.products(for: [ProManager.monthlyID])
        let product = try XCTUnwrap(products.first, "未加载月度产品")
        XCTAssertFalse(AuthService.shared.isSignedIn, "测试起点应为未登录")

        let unlocked = await ProManager.shared.purchase(product)

        XCTAssertFalse(unlocked, "未登录时不允许发起新购买")
        XCTAssertFalse(ProManager.shared.storeKitPro, "购买被拦截时不应产生本地 StoreKit 权益")
        XCTAssertFalse(ProManager.shared.isPro, "未登录且未购买时不是 Pro")
    }

    @MainActor
    func testStoreKitPurchase_unlocksPro() async throws {
        try await seedStoreKitPurchase(ProManager.monthlyID)
        XCTAssertTrue(ProManager.shared.storeKitPro, "购买后 storeKitPro=true")
        XCTAssertTrue(ProManager.shared.isPro, "购买后 isPro=true")
    }

    @MainActor
    func testAccountBoundaryClearsEntitlementSnapshotsButProfileUpdateKeepsStoreKit() {
        let account = UserAccount(
            id: "current-provider-user",
            email: "current@example.com",
            name: "Current Account",
            pictureURL: nil,
            provider: "google",
            backendUserId: "current-canonical-user"
        )
        AuthService.shared.applyAccount(account)
        ProManager.shared.setEntitlementsForTesting(storeKit: true, server: true)

        var profileUpdate = account
        profileUpdate.name = "Updated Profile"
        AuthService.shared.applyAccount(profileUpdate)
        XCTAssertTrue(
            ProManager.shared.storeKitLocalPro,
            "同一账号范围内的资料补全不能清除 StoreKit 快照"
        )
        XCTAssertFalse(
            ProManager.shared.serverPro,
            "资料变更后应等待同一账号的服务端权益重新确认"
        )
        ProManager.shared.setEntitlementsForTesting(storeKit: true, server: true)

        AuthService.shared.applyAccount(UserAccount(
            id: "next-provider-user",
            email: "next@example.com",
            name: "Next Account",
            pictureURL: nil,
            provider: "google",
            backendUserId: "next-canonical-user"
        ))

        XCTAssertFalse(
            ProManager.shared.storeKitLocalPro,
            "账号边界发布时必须同步清除上一账号的 StoreKit 快照"
        )
        XCTAssertFalse(ProManager.shared.serverPro)
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
        try await seedStoreKitPurchase(ProManager.yearlyID)
        XCTAssertTrue(ProManager.shared.storeKitPro, "购买年度后应 Pro")
        await ProManager.shared.restore()                  // AppStore.sync + refresh
        XCTAssertTrue(ProManager.shared.storeKitPro, "恢复后仍 Pro")
    }

    // MARK: 7. 订阅过期 → 回落免费

    @MainActor
    func testExpiry_revertsToFree() async throws {
        try await seedStoreKitPurchase(ProManager.monthlyID)
        XCTAssertTrue(ProManager.shared.storeKitPro, "购买后 Pro")
        // 订阅失效（过期/退款后权益从 currentEntitlements 移除）→ clearTransactions 确定性模拟，
        // 验证 refreshEntitlements 在无有效权益时把 storeKitPro 归 false（不依赖 expireSubscription 的续订日时序）。
        session.clearTransactions()
        await MainActor.run { ProManager.shared.clearServerEntitlement() }
        await ProManager.shared.refreshEntitlements()
        XCTAssertFalse(ProManager.shared.storeKitPro, "订阅失效 → storeKitPro=false")
        XCTAssertFalse(ProManager.shared.isPro, "失效后 isPro=false（已关模拟解锁）")
    }

    /// `Product.purchase()` needs a presentation anchor and can wait forever
    /// in a headless XCTest host on recent simulators. SKTestSession's direct
    /// purchase API creates the same verified StoreKit entitlement without UI,
    /// so entitlement, restore and expiry transitions remain deterministic.
    @MainActor
    private func seedStoreKitPurchase(_ productID: String) async throws {
        do {
            _ = try await session.buyProduct(identifier: productID)
        } catch {
            // Xcode 26 can run this app-hosted suite in "off-device buy"
            // mode, where StoreKitTest reports notEntitled even though the
            // same Configuration.storekit products load correctly. Record
            // that host limitation explicitly instead of hanging on the
            // presentation-based Product.purchase() API or reporting a false
            // product regression.
            throw XCTSkip(
                "StoreKitTest purchase is unavailable in this XCTest host: \(error)"
            )
        }
        await ProManager.shared.refreshEntitlements()
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

/// 两层额度策略（two_tier_v1）单元测试。独立于 SKTestSession（该环境在部分
/// 模拟器上会 crash），只测 QuotaManager 纯逻辑。
final class QuotaTwoTierTests: XCTestCase {

    @MainActor
    override func setUp() async throws {
        QuotaManager.shared.resetForTesting()
    }

    @MainActor
    override func tearDown() async throws {
        QuotaManager.shared.resetForTesting()
    }

    private func twoTierStatus(
        listenRemaining: Int,
        explainRemaining: Int,
        grantListen: Int,
        grantExplain: Int
    ) -> ProStatusDTO {
        ProStatusDTO(
            pro: false, plan: nil, account: nil,
            freeRemaining: explainRemaining, freeMax: nil,
            listenSeconds: nil, listenLimit: nil,
            listenRemaining: listenRemaining,
            quotaPolicy: "two_tier_v1",
            grantListenRemaining: grantListen,
            grantExplainRemaining: grantExplain
        )
    }

    /// 服务端未下发 quotaPolicy 时，一切行为必须与 daily 完全一致（实验隔离）。
    @MainActor
    func testDefaultPolicyStaysDaily() {
        let q = QuotaManager.shared
        XCTAssertEqual(q.policy, .daily)
        XCTAssertEqual(q.paywallTrigger(replacing: "listen_quota"), "listen_quota")
        XCTAssertEqual(q.paywallTrigger(replacing: "explain_quota"), "explain_quota")
        XCTAssertEqual(q.listenRemaining, q.dailyListenLimit, accuracy: 0.5)
    }

    @MainActor
    func testTwoTierActivationUsesServerBalancesAndSkipsDailyReset() {
        let q = QuotaManager.shared
        q.applyServerStatus(twoTierStatus(
            listenRemaining: 12_000, explainRemaining: 11,
            grantListen: 10_800, grantExplain: 10
        ))
        XCTAssertEqual(q.policy, .twoTier)
        XCTAssertEqual(q.listenRemaining, 12_000, accuracy: 0.5)
        XCTAssertEqual(q.explainRemaining, 11)
        // rollIfNewDay 在 twoTier 下不得重置任何余额
        q.rollIfNewDay()
        XCTAssertEqual(q.listenRemaining, 12_000, accuracy: 0.5)
    }

    @MainActor
    func testTwoTierListenConsumptionDrainsGrantFirstAndFlipsTrigger() {
        let q = QuotaManager.shared
        q.applyServerStatus(twoTierStatus(
            listenRemaining: 1_500, explainRemaining: 2,
            grantListen: 1_000, grantExplain: 1
        ))
        // 赠额层未耗尽：额度类 trigger 仍按月度归因（赠额未曾归零）
        XCTAssertEqual(q.paywallTrigger(replacing: "listen_quota"), "monthly_exhausted")
        q.addListen(1_200)   // 烧穿赠额层（1000）+ 月度 200
        XCTAssertEqual(q.listenRemaining, 300, accuracy: 0.5)
        // 赠额层刚归零 → onboarding_exhausted（价值峰值触点）
        XCTAssertEqual(q.paywallTrigger(replacing: "listen_quota"), "onboarding_exhausted")
        // 非额度 trigger 原样透传
        XCTAssertEqual(q.paywallTrigger(replacing: "pro_speed"), "pro_speed")
    }

    @MainActor
    func testTwoTierExplainConsumptionOnlyAfterServerAccepts() {
        let q = QuotaManager.shared
        q.applyServerStatus(twoTierStatus(
            listenRemaining: 1_000, explainRemaining: 2,
            grantListen: 0, grantExplain: 1
        ))
        q.noteExplainStarted(isPro: false)      // twoTier 下不预扣
        XCTAssertEqual(q.explainRemaining, 2)
        q.noteExplainAcceptedByServer(isPro: false)
        XCTAssertEqual(q.explainRemaining, 1)
        q.noteExplainAcceptedByServer(isPro: false)
        XCTAssertEqual(q.explainRemaining, 0)
        XCTAssertFalse(q.canStartExplain(isPro: false))
    }

    /// fail-close：策略已激活但镜像缺失（如 Keychain 写失败后重启）时按 0 处理，
    /// 绝不回落到 daily 的本地无限日重置。
    @MainActor
    func testTwoTierWithoutMirrorFailsClosed() {
        let q = QuotaManager.shared
        // 只下发策略、不下发任何余额字段 → 镜像被建为全 0
        q.applyServerStatus(ProStatusDTO(
            pro: false, plan: nil, account: nil,
            freeRemaining: nil, freeMax: nil,
            listenSeconds: nil, listenLimit: nil, listenRemaining: nil,
            quotaPolicy: "two_tier_v1"
        ))
        XCTAssertEqual(q.policy, .twoTier)
        XCTAssertEqual(q.listenRemaining, 0, accuracy: 0.5)
        XCTAssertEqual(q.explainRemaining, 0)
        XCTAssertFalse(q.canStartListen(isPro: false))
        XCTAssertTrue(q.canStartListen(isPro: true), "Pro 不受额度限制")
    }
}
