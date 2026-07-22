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
    @Published var debugForcePro = (UserDefaults.standard.object(forKey: "debug_force_pro") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(debugForcePro, forKey: "debug_force_pro") }
    }
    #endif

    /// 当前设备可用 Pro。跨端 Pro 真相是 serverPro(email-primary)；StoreKit 本地权益只作为短期兼容放行。
    var isPro: Bool {
        #if DEBUG
        if debugForcePro { return true }
        #endif
        return storeKitLocalPro || serverPro
    }

    var isCrossPlatformPro: Bool {
        serverPro && AuthService.shared.normalizedEmail != nil
    }

    private static let appAccountTokenKey = "storekit_app_account_token_v1"
    private var updatesTask: Task<Void, Never>?
    private var serverEmail: String?

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

    /// 拉取服务端 Pro/额度（device_id + 可选 user_id），回填额度到 QuotaManager。
    func refreshServer() async {
        let userId = await AuthService.shared.ensureBackendUserIdForPro()
        let email = AuthService.shared.normalizedEmail
        if email == nil {
            debugLog("status EMAIL missing; device_id is quota-only and will not grant cross-platform Pro")
            serverPro = false
            serverPlan = nil
            serverAccount = nil
            serverEmail = nil
        } else if serverEmail != nil && serverEmail != email {
            debugLog("status account changed; clearing previous server entitlement before refresh")
            serverPro = false
            serverPlan = nil
            serverAccount = nil
            serverEmail = nil
        }
        guard let status = await ProBackendService.shared.fetchStatus(userId: userId, email: email) else { return }
        serverPro = email != nil && status.pro
        if status.pro && email == nil {
            debugLog("status ignored server pro without email; source must be email-primary")
        }
        serverPlan = status.plan
        serverAccount = status.account
        serverEmail = email
        QuotaManager.shared.applyServerStatus(status)
        refreshSyncState(reason: "refresh-server")
    }

    /// 登出时清服务端权益（避免 refreshServer 网络失败 fail-open 时 serverPro 滞留为旧的 true）。
    func clearServerEntitlement() {
        serverPro = false
        serverPlan = nil
        serverAccount = nil
        serverEmail = nil
        refreshSyncState(reason: "clear-server")
    }

    /// 打开系统「管理订阅」面板（模拟器不支持）。
    func openManageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
    }

    var monthly: Product? { products.first { $0.id == Self.monthlyID } }
    var yearly: Product? { products.first { $0.id == Self.yearlyID } }

    // MARK: - 加载与刷新

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            // 按价格排序（月在前）
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            // fail-open：拉取失败保持空列表，UI 显示占位
            print("⚠️ [Pro] loadProducts failed: \(error)")
        }
    }

    func refreshEntitlements() async {
        var active = false
        var latestSignedTransaction: String?
        var latestExpiration = Date.distantPast
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            guard Self.productIDs.contains(t.productID) else { continue }
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
        if active,
           AuthService.shared.normalizedEmail != nil,
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
        guard AuthService.shared.normalizedEmail != nil else {
            refreshSyncState(reason: "purchase-blocked-missing-email")
            debugLog("purchase BLOCK missing-email product=\(product.id) localStoreKit=\(storeKitLocalPro ? "Y" : "N")")
            ProductAnalytics.shared.track(
                .purchaseResult,
                context: analyticsContext,
                properties: .init(
                    result: AnalyticsResult.blocked.rawValue,
                    errorCode: "email_required",
                    trigger: analyticsTrigger,
                    store: "app_store",
                    productId: product.id
                )
            )
            return false
        }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase(options: [.appAccountToken(Self.appAccountToken)])
            switch result {
            case .success(let verification):
                // verified / unverified 都要 finish，否则已扣费的交易会反复回到队列；
                // 权益以 refresh 后的 currentEntitlements 为准（unverified 不计权益，安全）。
                if case .verified(let t) = verification {
                    debugTransaction("purchase verified", t)
                    await t.finish()
                } else if case .unverified(let t, _) = verification {
                    debugTransaction("purchase unverified", t)
                    await t.finish()
                }
                await refresh()
                ProductAnalytics.shared.track(
                    .purchaseResult,
                    context: analyticsContext,
                    properties: .init(
                        result: isPro ? AnalyticsResult.success.rawValue : AnalyticsResult.failed.rawValue,
                        errorCode: isPro ? nil : "entitlement_not_active",
                        trigger: analyticsTrigger,
                        store: "app_store",
                        productId: product.id
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
                            activationSource: "storekit_verified"
                        )
                    )
                }
                return isPro
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
                await ProManager.shared.debugTransaction("transaction update", t)
                await t.finish()
                await ProManager.shared.refresh()
            }
        }
    }

    private static var appAccountToken: UUID {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: appAccountTokenKey), let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        d.set(id.uuidString, forKey: appAccountTokenKey)
        return id
    }

    private func setStoreKitLocalPro(_ active: Bool, reason: String) {
        storeKitLocalPro = active
        storeKitPro = active
        refreshSyncState(reason: reason)
    }

    func refreshSyncState(reason: String) {
        let hasEmail = AuthService.shared.normalizedEmail != nil
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
