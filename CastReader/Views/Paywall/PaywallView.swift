//
//  PaywallView.swift
//  CastReader
//
//  付费墙（额度耗尽/选 Pro 功能时弹出）。共享购买 UI = ProUpsellContent。
//

import SwiftUI
import StoreKit

enum PaywallPurchaseCTAAction: Equatable {
    case presentLogin
    case beginPurchase
}

struct PaywallAccountGateCompletion: Equatable {
    let purchaseAttemptId: String
    let productId: String
    let result: AnalyticsAccountGateResult
    let gatePresented: Bool
    let durationMs: Int
    let errorCode: String?
}

struct PaywallPurchaseCTAResolution: Equatable {
    let action: PaywallPurchaseCTAAction
    let purchaseAttemptId: String
    let accountGateCompletion: PaywallAccountGateCompletion?
}

enum PaywallPurchaseIntentPhase: String, Codable, Equatable {
    case awaitingLogin
    case readyToContinue
    case purchasing
}

/// Persists correlation only; restoration never invokes StoreKit. A login or
/// relaunch always requires another explicit CTA tap before purchase begins.
struct PaywallPurchaseIntentState: Codable, Equatable {
    private struct Attempt: Codable, Equatable {
        let purchaseAttemptId: String
        let productId: String
        let scope: String
        let startedAt: Date
        var phase: PaywallPurchaseIntentPhase
    }

    private var attempt: Attempt?

    var pendingProductId: String? {
        attempt?.phase == .awaitingLogin ? attempt?.productId : nil
    }

    var activePurchaseAttemptId: String? { attempt?.purchaseAttemptId }
    var hasActiveAttempt: Bool { attempt != nil }

    func isReadyToContinue(
        productId: String,
        scope: String = "paywall|unknown"
    ) -> Bool {
        attempt?.productId == productId
            && attempt?.scope == scope
            && attempt?.phase == .readyToContinue
    }

    mutating func selectedProductChanged(to productId: String?) {
        guard attempt?.productId != productId else { return }
        attempt = nil
    }

    mutating func resolveCTA(
        productId: String,
        isSignedIn: Bool,
        scope: String = "paywall|unknown",
        now: Date = Date(),
        newPurchaseAttemptId: String = UUID().uuidString
    ) -> PaywallPurchaseCTAResolution {
        if !isSignedIn {
            if attempt?.productId != productId
                || attempt?.scope != scope
                || attempt?.phase != .awaitingLogin {
                attempt = Attempt(
                    purchaseAttemptId: normalizedAttemptId(newPurchaseAttemptId),
                    productId: productId,
                    scope: scope,
                    startedAt: now,
                    phase: .awaitingLogin
                )
            }
            return .init(
                action: .presentLogin,
                purchaseAttemptId: attempt?.purchaseAttemptId
                    ?? normalizedAttemptId(newPurchaseAttemptId),
                accountGateCompletion: nil
            )
        }

        if var current = attempt,
           current.productId == productId,
           current.scope == scope,
           current.phase == .readyToContinue {
            // The successful presented gate already emitted its one terminal
            // result. This explicit second tap only resumes that same intent.
            current.phase = .purchasing
            attempt = current
            return .init(
                action: .beginPurchase,
                purchaseAttemptId: current.purchaseAttemptId,
                accountGateCompletion: nil
            )
        }

        let id = normalizedAttemptId(newPurchaseAttemptId)
        attempt = Attempt(
            purchaseAttemptId: id,
            productId: productId,
            scope: scope,
            startedAt: now,
            phase: .purchasing
        )
        return .init(
            action: .beginPurchase,
            purchaseAttemptId: id,
            accountGateCompletion: .init(
                purchaseAttemptId: id,
                productId: productId,
                result: .success,
                gatePresented: false,
                durationMs: 0,
                errorCode: nil
            )
        )
    }

    mutating func completePresentedGate(
        isSignedIn: Bool,
        scope: String = "paywall|unknown",
        now: Date = Date()
    ) -> PaywallAccountGateCompletion? {
        guard var current = attempt,
              current.scope == scope,
              current.phase == .awaitingLogin else { return nil }
        let durationMs = max(
            0,
            Int((now.timeIntervalSince(current.startedAt) * 1_000).rounded())
        )
        if isSignedIn {
            current.phase = .readyToContinue
            attempt = current
            return .init(
                purchaseAttemptId: current.purchaseAttemptId,
                productId: current.productId,
                result: .success,
                gatePresented: true,
                durationMs: durationMs,
                errorCode: nil
            )
        }

        attempt = nil
        return .init(
            purchaseAttemptId: current.purchaseAttemptId,
            productId: current.productId,
            result: .cancelled,
            gatePresented: true,
            durationMs: durationMs,
            errorCode: "user_cancelled"
        )
    }

    @discardableResult
    mutating func completePurchase(purchaseAttemptId: String) -> Bool {
        guard attempt?.purchaseAttemptId == purchaseAttemptId,
              attempt?.phase == .purchasing else { return false }
        attempt = nil
        return true
    }

    /// A process cannot safely infer the StoreKit result after a crash. Keep
    /// server/StoreKit transaction authority untouched and require a new tap.
    mutating func discardInterruptedPurchase() {
        guard attempt?.phase == .purchasing else { return }
        attempt = nil
    }

    private func normalizedAttemptId(_ candidate: String) -> String {
        UUID(uuidString: candidate)?.uuidString ?? UUID().uuidString
    }
}

struct UserDefaultsPaywallPurchaseIntentStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "paywall_purchase_intent_v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PaywallPurchaseIntentState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(
                PaywallPurchaseIntentState.self,
                from: data
              ) else { return PaywallPurchaseIntentState() }
        return state
    }

    @discardableResult
    func save(_ state: PaywallPurchaseIntentState) -> Bool {
        if !state.hasActiveAttempt {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        } else {
            return false
        }
        return defaults.synchronize()
    }
}

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = ProManager.shared
    let reason: String?
    let analyticsTrigger: String
    let analyticsSurface: String
    let onPurchased: () -> Void
    @State private var didTrackImpression = false
    @State private var didFinishPurchaseCallback = false
    @State private var didTrackDismissal = false
    @State private var selectedProductID: String?

    init(
        reason: String? = nil,
        analyticsTrigger: String = "unknown",
        analyticsSurface: String = "paywall",
        onPurchased: @escaping () -> Void = {}
    ) {
        self.reason = reason
        self.analyticsTrigger = analyticsTrigger
        self.analyticsSurface = analyticsSurface
        self.onPurchased = onPurchased
    }

    var body: some View {
        NavigationStack {
            ProUpsellContent(
                reason: reason,
                analyticsTrigger: analyticsTrigger,
                analyticsSurface: analyticsSurface,
                onPurchased: finishPurchase,
                onSelectionChanged: { selectedProductID = $0 }
            )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { closePaywall() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel(Text("关闭"))
                    }
                }
        }
        .task {
            if pro.isCrossPlatformPro { finishPurchase() }
        }
        .onAppear {
            guard !didTrackImpression else { return }
            didTrackImpression = true
            ProductAnalytics.shared.track(
                .paywallShown,
                context: AnalyticsEventContext(productArea: .billing, surface: analyticsSurface, entryPoint: analyticsTrigger),
                properties: .init(
                    trigger: analyticsTrigger,
                    entitlementState: Self.entitlementState(pro),
                    hadMeaningfulReading: ProductAnalytics.shared.hadMeaningfulReading,
                    configId: GrowthLoopConversionCoordinator.shared.activeConfigID,
                    valueMilestone: Self.valueMilestone(for: analyticsTrigger),
                    offerEligible: Self.defaultOfferEligible(pro),
                    selectedProductId: Self.defaultProduct(pro)?.id
                )
            )
        }
        .onChange(of: pro.isCrossPlatformPro) { isPro in
            if isPro { finishPurchase() }
        }
        .onDisappear { trackDismissalIfNeeded() }
    }

    private func finishPurchase() {
        guard !didFinishPurchaseCallback else { return }
        didFinishPurchaseCallback = true
        onPurchased()
        dismiss()
    }

    private func closePaywall() {
        trackDismissalIfNeeded()
        dismiss()
    }

    private func trackDismissalIfNeeded() {
        guard didTrackImpression,
              !didFinishPurchaseCallback,
              !didTrackDismissal else { return }
        didTrackDismissal = true
        let product = pro.displayProducts.first {
            $0.id == selectedProductID
        } ?? Self.defaultProduct(pro)
        let offerEligible = product.map { pro.showsFreeTrial(for: $0) }
        ProductAnalytics.shared.trackPaywallAction(
            productId: product?.id ?? "unknown",
            action: .dismissed,
            trigger: analyticsTrigger,
            surface: analyticsSurface,
            offerEligible: offerEligible,
            trialDays: product.flatMap { offerEligible == true ? ProManager.freeTrialDays(for: $0) : nil }
        )
    }

    private static func defaultProduct(_ pro: ProManager) -> Product? {
        pro.displayProducts.first {
            $0.subscription?.subscriptionPeriod.unit == .year
        } ?? pro.displayProducts.first
    }

    private static func defaultOfferEligible(_ pro: ProManager) -> Bool? {
        guard let product = defaultProduct(pro) else { return nil }
        return pro.showsFreeTrial(for: product)
    }

    private static func valueMilestone(for trigger: String) -> String? {
        switch trigger {
        case "growth_library_ready": return "library_ready"
        case "growth_listen_30s": return "listen_30s"
        case "growth_first_value_preview": return "listen_300s"
        default: return nil
        }
    }

    private static func entitlementState(_ pro: ProManager) -> String {
        if pro.isCrossPlatformPro { return "pro" }
        if pro.storeKitLocalPro { return "storekit_local_only" }
        if pro.serverPro { return "server_pro" }
        return "free"
    }
}

/// Pro 权益 + 购买按钮（PaywallView 与 UpgradeView 共用）。
struct ProUpsellContent: View {
    var reason: String? = nil
    var analyticsTrigger: String = "unknown"
    var analyticsSurface: String = "paywall"
    var onPurchased: () -> Void = {}
    var onSelectionChanged: (String?) -> Void = { _ in }

    private let purchaseIntentStore: UserDefaultsPaywallPurchaseIntentStore

    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var busy = false
    @State private var showLogin = false
    @State private var loadFailed = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    @State private var showPurchaseAlert = false
    @State private var purchaseMessage = ""
    @State private var selectedProductID: String?
    @State private var didTrackDefaultSelection = false
    @State private var purchaseIntent: PaywallPurchaseIntentState

    init(
        reason: String? = nil,
        analyticsTrigger: String = "unknown",
        analyticsSurface: String = "paywall",
        onPurchased: @escaping () -> Void = {},
        onSelectionChanged: @escaping (String?) -> Void = { _ in }
    ) {
        self.reason = reason
        self.analyticsTrigger = analyticsTrigger
        self.analyticsSurface = analyticsSurface
        self.onPurchased = onPurchased
        self.onSelectionChanged = onSelectionChanged
        let key = ServiceRouting.current.isolatedStorageKey(
            "paywall_purchase_intent_v1"
        )
        let store = UserDefaultsPaywallPurchaseIntentStore(key: key)
        self.purchaseIntentStore = store
        _purchaseIntent = State(initialValue: store.load())
    }

    private let benefits: [(String, String)] = [
        ("books.vertical.fill", AppLocalized("你的整个书库，全部可听")),
        ("infinity", AppLocalized("无限朗读时长")),
        ("sparkles", AppLocalized("无限解读次数")),
        ("waveform", AppLocalized("全部高级音色")),
        ("hare.fill", AppLocalized("最高 3x 语速")),
    ]

    /// 价值锚点：把参照物从「免费 TTS」换成「单本有声书」。动态取年付的
    /// 月均价（本币格式化），避免在静态文案里写死任何币种数字。
    @ViewBuilder
    private var priceAnchorLine: some View {
        if let yearly = pro.displayProducts.first(where: {
            $0.subscription?.subscriptionPeriod.unit == .year
        }) {
            let monthlyEquivalent = yearly.priceFormatStyle.format(yearly.price / 12)
            Text(String(format: AppLocalized("一本有声书的价格，够你听整个书库一个月——低至 %@/月"), monthlyEquivalent))
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AppTheme.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if let reason, !reason.isEmpty { reasonBanner(reason) }
                priceAnchorLine
                benefitList
                buySection
                Button("恢复购买") {
                    Task {
                        busy = true
                        await pro.restore()
                        busy = false
                        restoreMessage = restoreResultMessage
                        showRestoreAlert = true
                    }
                }
                .font(.subheadline)
                .disabled(busy)
                accountRow
                termsRow
            }
            .padding(20)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showLogin, onDismiss: completeLoginGateIfNeeded) {
            LoginView()
        }
        .alert("恢复购买", isPresented: $showRestoreAlert) {
            Button("好", role: .cancel) {}
        } message: { Text(restoreMessage) }
        .alert(AppLocalized("购买未完成"), isPresented: $showPurchaseAlert) {
            Button(AppLocalized("好"), role: .cancel) {}
        } message: {
            Text(purchaseMessage)
        }
        .onAppear { Task { await reloadProducts(); syncDefaultSelection(); await pro.refresh() } }
        .onChange(of: pro.displayProducts.map(\.id)) { _ in syncDefaultSelection() }
        .onChange(of: auth.isSignedIn) { _, isSignedIn in
            if isSignedIn { completeLoginGateIfNeeded() }
        }
        .task {
            if pro.isCrossPlatformPro { onPurchased() }
        }
        .onChange(of: pro.isCrossPlatformPro) { isPro in if isPro { onPurchased() } }
        .onDisappear { completeLoginGateIfNeeded() }
    }

    /// 默认选中年付。必须在 onAppear 也调一次：产品已缓存时 `onChange` 不会触发，
    /// 选择留在 nil 会让购买按钮一直是禁用的灰色状态，试用文案也不显示。
    private func syncDefaultSelection() {
        let ids = pro.displayProducts.map(\.id)
        if selectedProductID == nil || !ids.contains(selectedProductID ?? "") {
            selectedProductID = pro.displayProducts.first {
                $0.subscription?.subscriptionPeriod.unit == .year
            }?.id ?? pro.displayProducts.first?.id
            purchaseIntent.selectedProductChanged(to: selectedProductID)
            persistPurchaseIntent()
        }
        onSelectionChanged(selectedProductID)
        guard !didTrackDefaultSelection,
              let product = selectedProduct,
              let interval = analyticsInterval(product) else { return }
        didTrackDefaultSelection = true
        ProductAnalytics.shared.trackPaywallPlanSelected(
            productId: product.id,
            selectionSource: .defaultSelection,
            interval: interval,
            trigger: analyticsTrigger,
            configId: GrowthLoopConversionCoordinator.shared.activeConfigID,
            offerEligible: pro.showsFreeTrial(for: product)
        )
    }

    /// 加载产品；加载后仍为空标记 loadFailed，供付费墙显示「重试」而非永久转圈。
    private func reloadProducts() async {
        loadFailed = false
        await pro.loadProducts()
        loadFailed = pro.products.isEmpty
    }

    @ViewBuilder
    private var accountRow: some View {
        if pro.needsEmailSync && !auth.hasSyncableAccount {
            Button { showLogin = true } label: {
                Text("登录").font(.caption.weight(.semibold))
            }
            Text("已检测到购买，请登录后同步会员")
                .font(.caption2)
                .foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
        } else if pro.needsEmailSync {
            Text("已检测到购买，本机已解锁；跨平台同步等待 Apple 验证接口。")
                .font(.caption)
                .foregroundColor(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
        } else if let acc = auth.account {
            Text("已登录：\(acc.displayName)")
                .font(.caption).foregroundColor(AppTheme.mutedForeground)
        } else {
            Button { showLogin = true } label: {
                Text("已在其他设备购买？登录恢复 Pro").font(.caption.weight(.semibold))
            }
        }
    }

    private var termsRow: some View {
        VStack(spacing: 4) {
            Text("自动续订订阅，当前周期结束前 24 小时自动续费；可随时在 App Store 设置中取消。")
            HStack(spacing: 4) {
                Link("服务条款", destination: URL(string: Constants.API.termsURL)!)
                Text("·")
                Link("隐私政策", destination: URL(string: Constants.API.privacyURL)!)
            }
        }
        .font(.caption2).foregroundColor(AppTheme.mutedForeground)
        .multilineTextAlignment(.center)
    }

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(.white.opacity(0.18)).frame(width: 62, height: 62)
                Image(systemName: "headphones")
                    .font(.system(size: 31, weight: .semibold)).foregroundStyle(.white)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.yellow)
                    .offset(x: 23, y: -22)
            }
            Text("CASTREADER PRO").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.88))
            Text("聆听更多，理解更深").font(.title2.weight(.bold)).foregroundStyle(.white)
            Text("解锁完整朗读、解读与高级声音体验")
                .font(.subheadline).foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(
            LinearGradient(
                colors: [AppTheme.primary, Color(red: 1, green: 0.48, blue: 0.20), Color(red: 0.30, green: 0.24, blue: 0.64)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func reasonBanner(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(AppTheme.primary)
            Text(reason).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.foreground)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.primary.opacity(0.18)))
    }

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(benefits, id: \.1) { item in
                HStack(spacing: 14) {
                    Image(systemName: item.0)
                        .foregroundColor(AppTheme.primary)
                        .frame(width: 28)
                    Text(item.1).font(.body)
                    Spacer()
                    Image(systemName: "checkmark").foregroundColor(.green)
                }
            }
        }
        .padding(18)
        .background(AppTheme.surface)
        .cornerRadius(8)
    }

    @ViewBuilder
    private var buySection: some View {
        if pro.isCrossPlatformPro {
            Label("你已是 Pro 会员", systemImage: "checkmark.seal.fill")
                .foregroundColor(.green).font(.headline)
        } else if pro.storeKitLocalPro {
            VStack(spacing: 10) {
                Label("已检测到购买，请登录后同步会员", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundColor(AppTheme.primary)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(auth.hasSyncableAccount
                     ? AppLocalized("本机已解锁；跨平台同步等待 Apple 验证接口。")
                     : AppLocalized("已检测到购买，请登录后同步会员"))
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                if !auth.hasSyncableAccount {
                    Button("登录") { showLogin = true }
                        .font(.subheadline.weight(.semibold))
                }
            }
        } else if pro.products.isEmpty {
            VStack(spacing: 10) {
                if loadFailed {
                    Text("订阅信息加载失败").font(.subheadline).foregroundColor(AppTheme.mutedForeground)
                    Button("重试") { Task { await reloadProducts() } }.font(.subheadline.weight(.semibold))
                } else {
                    ProgressView("加载订阅…")
                }
            }
        } else {
            // 套餐与试用文案对未登录用户同样可见——把价格和「7 天免费试用」藏在登录之后，
            // 等于这个试用没上线。登录门槛只保留在「购买」这个动作上。
            VStack(spacing: 12) {
                ForEach(pro.displayProducts, id: \.id) { product in
                    Button {
                        selectProduct(product)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName).fontWeight(.semibold)
                                Text(periodText(product)).font(.caption).opacity(0.85)
                                if let savings = annualSavingsPercent(for: product) {
                                    Text(String(
                                        format: AppLocalized("比月付节省 %d%%"),
                                        savings
                                    ))
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.green)
                                }
                                if let days = trialDays(product) {
                                    Text(String(format: AppLocalized("%d 天免费试用"), days))
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(AppTheme.primary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(product.displayPrice).fontWeight(.bold)
                                if trialDays(product) != nil {
                                    Text(AppLocalized("试用结束后收费"))
                                        .font(.caption2)
                                        .foregroundColor(AppTheme.mutedForeground)
                                }
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(AppTheme.surface)
                        .foregroundColor(AppTheme.foreground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedProductID == product.id ? AppTheme.primary : AppTheme.border, lineWidth: selectedProductID == product.id ? 2 : 1)
                        )
                    }
                    .disabled(busy)
                }
                if isReadyToContinueSelectedProduct {
                    Label(AppLocalized("已登录"), systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Button {
                    handlePurchaseCTA()
                } label: {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        if !auth.isSignedIn { Image(systemName: "person.crop.circle.badge.checkmark") }
                        Text(primaryCTATitle).fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(busy || selectedProductID == nil)
                .accessibilityIdentifier("paywallPurchaseButton")

                if !auth.hasSyncableAccount {
                    Text(AppLocalized("登录可同步的账号后，Pro 可跨设备同步。"))
                        .font(.caption2)
                        .foregroundColor(AppTheme.mutedForeground)
                        .multilineTextAlignment(.center)
                }

                if let disclosure = trialDisclosure {
                    Text(disclosure)
                        .font(.caption2)
                        .foregroundColor(AppTheme.mutedForeground)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var selectedProduct: Product? {
        pro.displayProducts.first { $0.id == selectedProductID }
    }

    private var isReadyToContinueSelectedProduct: Bool {
        guard let selectedProductID else { return false }
        return purchaseIntent.isReadyToContinue(
            productId: selectedProductID,
            scope: purchaseIntentScope
        )
    }

    private var purchaseIntentScope: String {
        "\(analyticsSurface)|\(analyticsTrigger)"
    }

    private func selectProduct(_ product: Product) {
        selectedProductID = product.id
        purchaseIntent.selectedProductChanged(to: product.id)
        persistPurchaseIntent()
        onSelectionChanged(product.id)
        trackUserSelection(product)
    }

    private func handlePurchaseCTA() {
        guard !busy, let product = selectedProduct else { return }
        let resolution = purchaseIntent.resolveCTA(
            productId: product.id,
            isSignedIn: auth.isSignedIn,
            scope: purchaseIntentScope
        )
        persistPurchaseIntent()
        let offerEligible = pro.showsFreeTrial(for: product)
        ProductAnalytics.shared.trackPaywallAction(
            productId: product.id,
            action: .ctaTapped,
            trigger: analyticsTrigger,
            surface: analyticsSurface,
            offerEligible: offerEligible,
            trialDays: offerEligible ? ProManager.freeTrialDays(for: product) : nil,
            purchaseAttemptId: resolution.purchaseAttemptId
        )
        if let completion = resolution.accountGateCompletion {
            trackAccountGateCompletion(completion)
        }
        switch resolution.action {
        case .presentLogin:
            showLogin = true
        case .beginPurchase:
            beginPurchase(
                product,
                purchaseAttemptId: resolution.purchaseAttemptId
            )
        }
    }

    private func beginPurchase(
        _ product: Product,
        purchaseAttemptId: String
    ) {
        // StoreKit is intentionally entered only from this explicit user tap.
        // Login success restores the intent and CTA, but never auto-purchases.
        busy = true
        Task {
            let purchased = await pro.purchase(
                product,
                analyticsTrigger: analyticsTrigger,
                purchaseAttemptId: purchaseAttemptId
            )
            busy = false
            _ = purchaseIntent.completePurchase(
                purchaseAttemptId: purchaseAttemptId
            )
            persistPurchaseIntent()
            if purchased {
                onPurchased()
                return
            }
            purchaseMessage = AppLocalized(
                "购买尚未完成。请稍后重试；若交易正在等待批准，获批后会员会自动生效。"
            )
            showPurchaseAlert = true
        }
    }

    private func completeLoginGateIfNeeded() {
        guard let completion = purchaseIntent.completePresentedGate(
            isSignedIn: auth.isSignedIn,
            scope: purchaseIntentScope
        ) else { return }
        persistPurchaseIntent()
        trackAccountGateCompletion(completion)
    }

    private func trackAccountGateCompletion(_ completion: PaywallAccountGateCompletion) {
        ProductAnalytics.shared.trackAccountGateResult(
            productId: completion.productId,
            result: completion.result,
            gatePresented: completion.gatePresented,
            trigger: analyticsTrigger,
            surface: analyticsSurface,
            durationMs: completion.durationMs,
            errorCode: completion.errorCode,
            purchaseAttemptId: completion.purchaseAttemptId
        )
    }

    private func persistPurchaseIntent() {
        let persisted = purchaseIntentStore.save(purchaseIntent)
#if DEBUG
        if !persisted {
            print("[Analytics] paywall purchase intent persistence failed")
        }
#endif
    }

    private func trackUserSelection(_ product: Product) {
        guard let interval = analyticsInterval(product) else { return }
        ProductAnalytics.shared.trackPaywallPlanSelected(
            productId: product.id,
            selectionSource: .user,
            interval: interval,
            trigger: analyticsTrigger,
            configId: GrowthLoopConversionCoordinator.shared.activeConfigID,
            offerEligible: pro.showsFreeTrial(for: product)
        )
    }

    private func analyticsInterval(_ product: Product) -> AnalyticsPlanInterval? {
        switch product.subscription?.subscriptionPeriod.unit {
        case .month: return .monthly
        case .year: return .yearly
        default: return nil
        }
    }

    private func annualSavingsPercent(for product: Product) -> Int? {
        guard product.subscription?.subscriptionPeriod.unit == .year,
              let monthly = pro.displayProducts.first(where: {
                  $0.subscription?.subscriptionPeriod.unit == .month
              }) else { return nil }
        return SubscriptionPlanSavings.percentage(
            monthlyPrice: monthly.price,
            yearlyPrice: product.price
        )
    }

    /// 有资格才显示试用天数；没资格的老用户走原有价格文案。
    private func trialDays(_ product: Product) -> Int? {
        guard pro.showsFreeTrial(for: product) else { return nil }
        return ProManager.freeTrialDays(for: product)
    }

    private var primaryCTATitle: String {
        let title: String
        if let product = selectedProduct, let days = trialDays(product) {
            title = String(format: AppLocalized("开始 %d 天免费试用"), days)
        } else {
            title = AppLocalized("升级到 CastReader Pro")
        }
        guard isReadyToContinueSelectedProduct else { return title }
        return "\(AppLocalized("继续")) · \(title)"
    }

    /// Apple 3.1.2：试用必须在购买点明示「试用时长 + 到期价格 + 自动续订 + 可取消」。
    private var trialDisclosure: String? {
        guard let product = selectedProduct, let days = trialDays(product) else { return nil }
        return String(
            format: AppLocalized("免费试用 %1$d 天，之后按 %2$@%3$@自动续订。可随时在 App Store 设置中取消。"),
            days,
            product.displayPrice,
            perPeriodSuffix(product)
        )
    }

    /// 「/月」「/年」后缀，拼在价格后面构成“$34.99/年”。
    private func perPeriodSuffix(_ p: Product) -> String {
        switch p.subscription?.subscriptionPeriod.unit {
        case .month: return AppLocalized("/月")
        case .year: return AppLocalized("/年")
        case .week: return AppLocalized("/周")
        case .day: return AppLocalized("/天")
        default: return ""
        }
    }

    private var restoreResultMessage: String {
        if pro.isCrossPlatformPro {
            return AppLocalized("已恢复 Pro 会员")
        }
        if pro.storeKitLocalPro {
            if auth.hasSyncableAccount {
                return AppLocalized("已恢复购买，本机已解锁；跨平台同步等待 Apple 验证接口。")
            }
            return AppLocalized("已检测到购买，请登录后同步会员")
        }
        return AppLocalized("未找到可恢复的购买")
    }

    /// 订阅周期文案（满足 Apple 3.1.2：购买点附近明示订阅时长）。
    private func periodText(_ p: Product) -> String {
        switch p.subscription?.subscriptionPeriod.unit {
        case .month: return AppLocalized("按月订阅")
        case .year: return AppLocalized("按年订阅")
        case .week: return AppLocalized("按周订阅")
        case .day: return AppLocalized("按天订阅")
        default: return ""
        }
    }
}

enum SubscriptionPlanSavings {
    static func percentage(monthlyPrice: Decimal, yearlyPrice: Decimal) -> Int? {
        let monthly = NSDecimalNumber(decimal: monthlyPrice).doubleValue
        let yearly = NSDecimalNumber(decimal: yearlyPrice).doubleValue
        let twelveMonths = monthly * 12
        guard monthly > 0, yearly >= 0, yearly < twelveMonths else { return nil }
        return max(1, min(99, Int(((twelveMonths - yearly) / twelveMonths * 100).rounded())))
    }
}
