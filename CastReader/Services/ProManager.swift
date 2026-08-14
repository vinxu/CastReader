//
//  ProManager.swift
//  CastReader
//
//  StoreKit 2 订阅状态管理。fail-open：StoreKit 不可用/抛错时保留上次 isPro，不硬阻播放。
//

import Foundation
import StoreKit
import Combine
import UIKit
import CryptoKit

@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()

    /// 订阅产品 id（生产需在 App Store Connect 配置；本地用 Configuration.storekit）。
    static let monthlyID = "ai.castreader.pro.monthly"
    static let yearlyID = "ai.castreader.pro.yearly"
    static let productIDs: Set<String> = [monthlyID, yearlyID]

    @Published private(set) var storeKitLocalPro = false
    @Published private(set) var storeKitPro = false
    @Published private(set) var serverPro = false
    @Published private(set) var serverPlan: String?
    @Published private(set) var serverAccount: ProAccountDTO?
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchaseInFlight = false
    @Published private(set) var needsEmailSync = false

    #if DEBUG
    /// 仅 DEBUG：模拟 Pro 解锁开关（设置→调试可切换）。默认 true 保持开发期全解锁（方便反复测朗读/解读）；
    /// **关闭后 isPro 走真实内购/服务端权益**，用于本地测试付费流程与跨平台继承。发布构建不含此开关。
    /// `-CastReaderDisableDebugPro` 可在启动时强制关闭，供 UI 测试与商店素材采集走真实的免费用户视角
    /// （UserDefaults 启动参数覆盖不了这里：`-debug_force_pro NO` 会被当成字符串，`as? Bool` 取不到）。
    @Published var debugForcePro = ProManager.initialDebugForcePro() {
        didSet { UserDefaults.standard.set(debugForcePro, forKey: "debug_force_pro") }
    }

    private static func initialDebugForcePro() -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-CastReaderDisableDebugPro") { return false }
        return UserDefaults.standard.object(forKey: "debug_force_pro") as? Bool ?? true
    }
    #endif

    /// 当前设备可用 Pro。跨端 Pro 真相是账号维度的 serverPro；StoreKit 本地权益只作为短期兼容放行。
    var isPro: Bool {
        #if DEBUG
        if debugForcePro { return true }
        #endif
        return storeKitLocalPro || serverPro
    }

    var isCrossPlatformPro: Bool {
        serverPro && AuthService.shared.hasSyncableAccount
    }

    private var updatesTask: Task<Void, Never>?
    /// 当前 `serverPro` 对应的账号身份。邮箱账号与纯手机号账号都必须参与，
    /// 否则两个无邮箱手机号账号之间切换且网络失败时会短暂沿用前一个人的权益。
    private var serverIdentity: String?

    private init() {}

    func start() {
        updatesTask?.cancel()
        updatesTask = listenForTransactions()
        Task {
            await loadProducts()
            await refresh()
        }
    }

    /// 刷新 StoreKit 权益 + 服务端 Pro/额度。在启动/前台/登录/购买后调用。
    func refresh() async {
        await refreshEntitlements()
        await refreshServer()
    }

    /// 用 cms_ 会话拉取服务端 Pro/额度；服务端从 canonical user + ingress route
    /// 派生额度主体，客户端 device_id 只保留为兼容字段，不能决定权益或额度。
    func refreshServer() async {
        let userId = Self.normalizedIdentityComponent(
            await AuthService.shared.ensureBackendUserIdForPro()
        )
        let email = Self.normalizedEmail(AuthService.shared.normalizedEmail)
        let identity = Self.serverIdentityKey(userId: userId, email: email)

        if identity == nil {
            debugLog("status account identity missing; authenticated quota unavailable")
            clearServerEntitlement()
            return
        } else if serverIdentity != nil && serverIdentity != identity {
            debugLog("status account changed; clearing previous server entitlement before refresh")
            clearServerEntitlement()
        }
        #if DEBUG
        // Explicit UI automation uses a deterministic local cms_ token to
        // exercise account boundaries without reaching production services.
        // Never send that token to Pro v2: its expected 401 would immediately
        // close the test account under the production rejection policy.
        if let token = await MobileSessionStore.shared.sessionToken(),
           MobileSessionStore.isExplicitUITestSessionToken(token) {
            clearServerEntitlement()
            return
        }
        #endif
        guard await AuthService.shared.ensureMobileSession() else {
            debugLog("status mobile session missing; clearing server entitlement")
            clearServerEntitlement()
            return
        }
        let outcome = await ProBackendService.shared.fetchStatus()
        let status: ProStatusDTO
        switch outcome {
        case .success(let value):
            status = value
        case .unauthorized(let rejectedToken):
            debugLog("status mobile session unauthorized; clearing server entitlement")
            clearServerEntitlement()
            await AuthService.shared.handleRejectedMobileSession(
                rejectedToken: rejectedToken
            )
            return
        case .unavailable:
            return // network/backend failure preserves the same account's last known state
        }
        guard Self.normalizedIdentityComponent(status.resolvedUserId) == userId else {
            debugLog("status principal mismatch; clearing server entitlement")
            clearServerEntitlement()
            guard AuthService.shared.proUserId == userId else { return }
            let rejectedToken = await MobileSessionStore.shared.sessionToken()
            await AuthService.shared.handleRejectedMobileSession(
                rejectedToken: rejectedToken
            )
            return
        }
        serverPro = Self.shouldAdoptServerPro(status.pro, userId: userId, email: email)
        serverPlan = status.plan
        serverAccount = status.account
        serverIdentity = identity
        // 服务端是账号资料的权威来源：邮箱验证码登录（better-auth 响应常不带
        // name/image）和 Apple 二次登录（Apple 只在首次授权给资料）都会拿到空的
        // 昵称/头像，这里把它们补回来，同一个后端账号在各端显示才一致。
        if let account = status.account {
            AuthService.shared.fillMissingProfile(name: account.name, pictureURL: account.image)
        }
        QuotaManager.shared.applyServerStatus(status)
        refreshSyncState(reason: "refresh-server")
    }

    /// 登出时清服务端权益（避免 refreshServer 网络失败 fail-open 时 serverPro 滞留为旧的 true）。
    func clearServerEntitlement() {
        serverPro = false
        serverPlan = nil
        serverAccount = nil
        serverIdentity = nil
        refreshSyncState(reason: "clear-server")
    }

    /// 规范化账号 id，避免仅含空白的后端字段被当作可同步身份。
    nonisolated static func normalizedIdentityComponent(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    nonisolated static func normalizedEmail(_ rawValue: String?) -> String? {
        normalizedIdentityComponent(rawValue)?.lowercased()
    }

    /// 同一路线内用于隔离内存权益的稳定账号指纹。两项都带上，任何一项变化都
    /// 会先清掉旧权益；手机号账号没有邮箱时仍可仅凭后端 user id 同步。
    nonisolated static func serverIdentityKey(userId: String?, email: String?) -> String? {
        let normalizedUserId = normalizedIdentityComponent(userId)
        let normalizedEmailValue = normalizedEmail(email)
        guard normalizedUserId != nil || normalizedEmailValue != nil else { return nil }
        return "user:\(normalizedUserId ?? "-")|email:\(normalizedEmailValue ?? "-")"
    }

    nonisolated static func shouldAdoptServerPro(
        _ statusPro: Bool,
        userId: String?,
        email: String?
    ) -> Bool {
        statusPro && serverIdentityKey(userId: userId, email: email) != nil
    }

    /// Build-39+ purchases use a recognizable UUIDv8 token bound to one
    /// authenticated backend account. It is deliberately route-independent:
    /// one App Store subscription belongs to the whole bundle, so legacy and
    /// CN ingress must share one account/billing authority and the same user id.
    /// Legacy releases used a device UUIDv4; those remain accepted for restore.
    nonisolated static func accountBoundAppAccountToken(
        userId: String
    ) -> UUID {
        let normalizedUserId = normalizedIdentityComponent(userId) ?? ""
        let input = "castreader-storekit-account-v3|\(normalizedUserId)"
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // UUID version 8 (application-defined)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    nonisolated static func isAccountBoundAppAccountToken(_ token: UUID?) -> Bool {
        guard var raw = token?.uuid else { return false }
        return withUnsafeBytes(of: &raw) { bytes in
            (bytes[6] >> 4) == 8
        }
    }

    /// Unknown/nil and UUIDv4 tokens are legacy-compatible. A UUIDv8 token is
    /// new-contract data and must match the currently authenticated account.
    nonisolated static func transactionBelongsToCurrentAccount(
        appAccountToken: UUID?,
        expectedAccountToken: UUID?
    ) -> Bool {
        guard isAccountBoundAppAccountToken(appAccountToken) else { return true }
        return appAccountToken == expectedAccountToken
    }

    /// Transaction.updates is process-wide. Only CastReader subscription
    /// products that belong to the currently authenticated account may be
    /// finished and followed by an entitlement refresh. Legacy UUIDv4/nil
    /// tokens intentionally retain the prior compatibility behavior.
    nonisolated static func shouldProcessTransactionUpdate(
        productID: String,
        appAccountToken: UUID?,
        expectedAccountToken: UUID?
    ) -> Bool {
        productIDs.contains(productID)
            && transactionBelongsToCurrentAccount(
                appAccountToken: appAccountToken,
                expectedAccountToken: expectedAccountToken
            )
    }

    nonisolated static func shouldFinishStoreKitTransaction(isVerified: Bool) -> Bool {
        isVerified
    }

    /// 打开系统「管理订阅」面板（模拟器不支持）。
    func openManageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
    }

    var monthly: Product? { products.first { $0.id == Self.monthlyID } }
    var yearly: Product? { products.first { $0.id == Self.yearlyID } }

    // MARK: - 免费试用资格

    /// 当前 Apple ID 仍可享受首购优惠的产品 id。
    /// 同一订阅组内试用只能用一次，所以这是**每个 Apple ID 一次性**的资格，必须按 StoreKit 的判断展示，
    /// 不能对所有人无条件写「7 天免费试用」——老用户看到却拿不到，会被 Apple 以 3.1.2 误导性订阅文案拒审。
    @Published private(set) var introOfferEligibleIDs: Set<String> = []

    /// 该产品是否应对当前用户展示免费试用（既有 offer，又还有资格）。
    func showsFreeTrial(for product: Product) -> Bool {
        introOfferEligibleIDs.contains(product.id) && Self.freeTrialDays(for: product) != nil
    }

    /// 首购优惠里的免费试用天数；不是免费试用（如首期折扣）或没有 offer 时返回 nil。
    nonisolated static func freeTrialDays(for product: Product) -> Int? {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let period = offer.period
        let perUnit: Int
        switch period.unit {
        case .day: perUnit = 1
        case .week: perUnit = 7
        case .month: perUnit = 30
        case .year: perUnit = 365
        @unknown default: return nil
        }
        let days = period.value * perUnit * offer.periodCount
        return days > 0 ? days : nil
    }

    #if DEBUG
    /// 仅测试：直接注入资格集合，确定性验证「无资格 → 不得承诺试用」的门控
    /// （StoreKitTest 的 buyProduct 在本仓库测试宿主下抛 notEntitled，无法用真实购买驱动翻转）。
    func setIntroOfferEligibilityForTesting(_ ids: Set<String>) {
        introOfferEligibleIDs = ids
    }
    #endif

    /// 刷新首购资格。fail-open：查询抛错时按「无试用」展示，宁可少承诺也不能多承诺。
    func refreshIntroOfferEligibility() async {
        var eligible: Set<String> = []
        for product in products {
            guard let subscription = product.subscription,
                  Self.freeTrialDays(for: product) != nil else { continue }
            if await subscription.isEligibleForIntroOffer {
                eligible.insert(product.id)
            }
        }
        introOfferEligibleIDs = eligible
    }

    // MARK: - 加载与刷新

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            // 按价格排序（月在前）
            products = loaded.sorted { $0.price < $1.price }
            await refreshIntroOfferEligibility()
        } catch {
            // fail-open：拉取失败保持空列表，UI 显示占位
            print("⚠️ [Pro] loadProducts failed: \(error)")
        }
    }

    func refreshEntitlements() async {
        var active = false
        var latestSignedTransaction: String?
        var latestExpiration = Date.distantPast
        let expectedAccountToken = await expectedStoreKitAccountToken()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            guard Self.productIDs.contains(t.productID) else { continue }
            guard Self.transactionBelongsToCurrentAccount(
                appAccountToken: t.appAccountToken,
                expectedAccountToken: expectedAccountToken
            ) else {
                debugTransaction("entitlement account-mismatch", t)
                continue
            }
            let notRevoked = t.revocationDate == nil
            let notExpired = (t.expirationDate ?? Date.distantFuture) > Date()
            if notRevoked && notExpired {
                active = true
                debugTransaction("entitlement", t)
                let expiration = t.expirationDate ?? Date.distantFuture
                if expiration > latestExpiration {
                    latestExpiration = expiration
                    latestSignedTransaction = result.jwsRepresentation
                }
            }
        }
        setStoreKitLocalPro(active, reason: "refresh-entitlements")
        await refreshIntroOfferEligibility()
        // 上报只要已登录就尝试：verify-apple 实际依赖 cms_ 会话（无会话时自 SKIP），
        // 拿 email 当前置条件会漏掉 Apple 无 email 但有会话的账号。
        if active,
           AuthService.shared.isSignedIn,
           let latestSignedTransaction {
            let synced = await ProBackendService.shared.verifyAppleTransaction(latestSignedTransaction)
            debugLog("storekit-server-sync result=\(synced ? "Y" : "N")")
        }
    }

    // MARK: - 购买 / 恢复

    @discardableResult
    func purchase(_ product: Product, analyticsTrigger: String = "unknown") async -> Bool {
        let purchaseAttemptId = UUID().uuidString
        let analyticsContext = AnalyticsEventContext(
            productArea: .billing,
            surface: "paywall",
            entryPoint: analyticsTrigger,
            purchaseAttemptId: purchaseAttemptId
        )
        ProductAnalytics.shared.track(
            .purchaseStart,
            context: analyticsContext,
            properties: .init(trigger: analyticsTrigger, store: "app_store", productId: product.id)
        )
        // 硬登录墙后所有人必然已登录；Apple 登录可能拿不到 email（仅首次授权返回），
        // 手机号账号同样算已登录。Build 39 起购买必须先拿到后端 user id，才能把
        // StoreKit appAccountToken 绑定到账号，避免待处理交易被另一个 CastReader
        // 账号认领；两条网络线路必须共享同一账号/账单权威，email 仍不是前置条件。
        guard AuthService.shared.isSignedIn else {
            refreshSyncState(reason: "purchase-blocked-signed-out")
            debugLog("purchase BLOCK signed-out product=\(product.id) localStoreKit=\(storeKitLocalPro ? "Y" : "N")")
            ProductAnalytics.shared.track(
                .purchaseResult,
                context: analyticsContext,
                properties: .init(
                    result: AnalyticsResult.blocked.rawValue,
                    errorCode: "signin_required",
                    trigger: analyticsTrigger,
                    store: "app_store",
                    productId: product.id
                )
            )
            return false
        }
        guard let backendUserId = Self.normalizedIdentityComponent(
            await AuthService.shared.ensureBackendUserIdForPro()
        ) else {
            refreshSyncState(reason: "purchase-blocked-account-sync")
            ProductAnalytics.shared.track(
                .purchaseResult,
                context: analyticsContext,
                properties: .init(
                    result: AnalyticsResult.blocked.rawValue,
                    errorCode: "account_sync_required",
                    trigger: analyticsTrigger,
                    store: "app_store",
                    productId: product.id
                )
            )
            return false
        }
        guard await AuthService.shared.ensureMobileSession() else {
            refreshSyncState(reason: "purchase-blocked-mobile-session")
            ProductAnalytics.shared.track(
                .purchaseResult,
                context: analyticsContext,
                properties: .init(
                    result: AnalyticsResult.blocked.rawValue,
                    errorCode: "mobile_session_required",
                    trigger: analyticsTrigger,
                    store: "app_store",
                    productId: product.id
                )
            )
            return false
        }
        let purchaseAccountToken = Self.accountBoundAppAccountToken(
            userId: backendUserId
        )
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase(
                options: [.appAccountToken(purchaseAccountToken)]
            )
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let t):
                    debugTransaction("purchase verified", t)
                    let transactionEnvironment = Self.analyticsEnvironment(for: t)
                    if Self.shouldFinishStoreKitTransaction(isVerified: true) {
                        await t.finish()
                    }
                    await refresh()
                    ProductAnalytics.shared.track(
                        .purchaseResult,
                        context: analyticsContext,
                        properties: .init(
                            result: isPro
                                ? AnalyticsResult.success.rawValue
                                : AnalyticsResult.failed.rawValue,
                            errorCode: isPro ? nil : "entitlement_not_active",
                            trigger: analyticsTrigger,
                            store: "app_store",
                            productId: product.id,
                            transactionEnvironment: transactionEnvironment
                        )
                    )
                    if isPro {
                        ProductAnalytics.shared.track(
                            .entitlementActivated,
                            context: analyticsContext,
                            properties: .init(
                                trigger: analyticsTrigger,
                                store: "app_store",
                                productId: product.id,
                                activationSource: "storekit_verified",
                                transactionEnvironment: transactionEnvironment
                            )
                        )
                    }
                    return isPro
                case .unverified(let t, _):
                    debugTransaction("purchase unverified", t)
                    // Never finish an unverified transaction. It may represent
                    // a legitimate charged purchase whose certificate check is
                    // temporarily failing; preserve it for Transaction.updates
                    // or an explicit restore after verification succeeds.
                    if Self.shouldFinishStoreKitTransaction(isVerified: false) {
                        await t.finish()
                    }
                    await refresh()
                    ProductAnalytics.shared.track(
                        .purchaseResult,
                        context: analyticsContext,
                        properties: .init(
                            result: AnalyticsResult.failed.rawValue,
                            errorCode: "transaction_unverified",
                            trigger: analyticsTrigger,
                            store: "app_store",
                            productId: product.id,
                            transactionEnvironment: Self.analyticsEnvironment(for: t)
                        )
                    )
                    return false
                }
            case .pending:
                ProductAnalytics.shared.track(
                    .purchaseResult,
                    context: analyticsContext,
                    properties: .init(
                        result: AnalyticsResult.pending.rawValue,
                        trigger: analyticsTrigger,
                        store: "app_store",
                        productId: product.id
                    )
                )
                return false   // 待批准（如家长 Ask to Buy）：完成后经 Transaction.updates 自动入账
            case .userCancelled:
                ProductAnalytics.shared.track(
                    .purchaseResult,
                    context: analyticsContext,
                    properties: .init(
                        result: AnalyticsResult.cancelled.rawValue,
                        trigger: analyticsTrigger,
                        store: "app_store",
                        productId: product.id
                    )
                )
                return false
            @unknown default:
                ProductAnalytics.shared.track(
                    .purchaseResult,
                    context: analyticsContext,
                    properties: .init(
                        result: AnalyticsResult.failed.rawValue,
                        errorCode: "unknown_storekit_result",
                        trigger: analyticsTrigger,
                        store: "app_store",
                        productId: product.id
                    )
                )
                return false
            }
        } catch {
            print("⚠️ [Pro] purchase failed: \(error)")
            ProductAnalytics.shared.track(
                .purchaseResult,
                context: analyticsContext,
                properties: .init(
                    result: AnalyticsResult.failed.rawValue,
                    errorCode: "storekit_error",
                    trigger: analyticsTrigger,
                    store: "app_store",
                    productId: product.id
                )
            )
            return false
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            print("⚠️ [Pro] restore sync failed: \(error)")
        }
        await refresh()
    }

    // MARK: - Transaction.updates 监听

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            for await update in Transaction.updates {
                guard case .verified(let t) = update else { continue }
                guard ProManager.productIDs.contains(t.productID) else {
                    await ProManager.shared.debugTransaction(
                        "transaction update ignored non-product",
                        t
                    )
                    continue
                }
                let expectedAccountToken = await ProManager.shared.expectedStoreKitAccountToken()
                guard ProManager.shouldProcessTransactionUpdate(
                    productID: t.productID,
                    appAccountToken: t.appAccountToken,
                    expectedAccountToken: expectedAccountToken
                ) else {
                    await ProManager.shared.debugTransaction(
                        "transaction update ignored account-mismatch",
                        t
                    )
                    continue
                }
                await ProManager.shared.debugTransaction("transaction update", t)
                await t.finish()
                await ProManager.shared.refresh()
            }
        }
    }

    /// Nil is deliberately fail-closed for UUIDv8 transactions. The legacy
    /// UUIDv4/nil compatibility decision remains centralized in
    /// `transactionBelongsToCurrentAccount`.
    private func expectedStoreKitAccountToken() async -> UUID? {
        guard AuthService.shared.isSignedIn,
              let userId = Self.normalizedIdentityComponent(
                  await AuthService.shared.ensureBackendUserIdForPro()
              ) else {
            return nil
        }
        return Self.accountBoundAppAccountToken(userId: userId)
    }

    private func setStoreKitLocalPro(_ active: Bool, reason: String) {
        storeKitLocalPro = active
        storeKitPro = active
        refreshSyncState(reason: reason)
    }

    func refreshSyncState(reason: String) {
        let hasEmail = AuthService.shared.hasSyncableAccount
        let pending = storeKitLocalPro && !serverPro
        needsEmailSync = pending
        if pending {
            debugLog("sync-needed reason=\(reason) hasEmail=\(hasEmail ? "Y" : "N") localStoreKit=Y server=N")
        }
        SafariExtensionBridge.syncFromApp()
    }

    private func debugTransaction(_ label: String, _ transaction: Transaction) {
        #if DEBUG
        print("[Pro] \(label) product=\(transaction.productID) tx=\(Self.redact("\(transaction.id)")) original=\(Self.redact("\(transaction.originalID)")) appAccount=\(Self.redact(transaction.appAccountToken?.uuidString)) expires=\(transaction.expirationDate?.description ?? "nil") revoked=\(transaction.revocationDate == nil ? "N" : "Y")")
        #endif
    }

    nonisolated private static func analyticsEnvironment(for transaction: Transaction) -> String {
        let value = transaction.environment.rawValue.lowercased()
        return ["production", "sandbox", "xcode"].contains(value)
            ? value
            : "unknown"
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[Pro] \(message)")
        #endif
    }

    private static func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        if value.count <= 8 { return "\(value.prefix(2))…" }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }
}
