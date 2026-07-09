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

    @Published private(set) var storeKitPro = false
    @Published private(set) var serverPro = false
    @Published private(set) var serverPlan: String?
    @Published private(set) var serverAccount: ProAccountDTO?
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchaseInFlight = false

    #if DEBUG
    /// 仅 DEBUG：模拟 Pro 解锁开关（设置→调试可切换）。默认 true 保持开发期全解锁（方便反复测朗读/解读）；
    /// **关闭后 isPro 走真实内购/服务端权益**，用于本地测试付费流程与跨平台继承。发布构建不含此开关。
    @Published var debugForcePro = (UserDefaults.standard.object(forKey: "debug_force_pro") as? Bool ?? true) {
        didSet { UserDefaults.standard.set(debugForcePro, forKey: "debug_force_pro") }
    }
    #endif

    /// 综合 Pro：iOS 内购 或 服务端账号 Pro（Web Stripe 付费者登录/设备关联后）。
    var isPro: Bool {
        #if DEBUG
        if debugForcePro { return true }
        #endif
        return storeKitPro || serverPro
    }

    private static let appAccountTokenKey = "storekit_app_account_token_v1"
    private var updatesTask: Task<Void, Never>?

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
        let email = AuthService.shared.account?.email
        guard let status = await ProBackendService.shared.fetchStatus(userId: userId, email: email) else { return }
        serverPro = status.pro
        serverPlan = status.plan
        serverAccount = status.account
        QuotaManager.shared.applyServerStatus(status)
    }

    /// 登出时清服务端权益（避免 refreshServer 网络失败 fail-open 时 serverPro 滞留为旧的 true）。
    func clearServerEntitlement() {
        serverPro = false
        serverPlan = nil
        serverAccount = nil
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
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            guard Self.productIDs.contains(t.productID) else { continue }
            let notRevoked = t.revocationDate == nil
            let notExpired = (t.expirationDate ?? Date.distantFuture) > Date()
            if notRevoked && notExpired {
                active = true
                debugTransaction("entitlement", t)
            }
        }
        storeKitPro = active
    }

    // MARK: - 购买 / 恢复

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
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
                return isPro
            case .pending:
                return false   // 待批准（如家长 Ask to Buy）：完成后经 Transaction.updates 自动入账
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            print("⚠️ [Pro] purchase failed: \(error)")
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

    private func debugTransaction(_ label: String, _ transaction: Transaction) {
        #if DEBUG
        print("[Pro] \(label) product=\(transaction.productID) tx=\(Self.redact("\(transaction.id)")) original=\(Self.redact("\(transaction.originalID)")) appAccount=\(Self.redact(transaction.appAccountToken?.uuidString)) expires=\(transaction.expirationDate?.description ?? "nil") revoked=\(transaction.revocationDate == nil ? "N" : "Y")")
        #endif
    }

    private static func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        if value.count <= 8 { return "\(value.prefix(2))…" }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }
}
