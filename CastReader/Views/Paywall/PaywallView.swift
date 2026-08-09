//
//  PaywallView.swift
//  CastReader
//
//  付费墙（额度耗尽/选 Pro 功能时弹出）。共享购买 UI = ProUpsellContent。
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pro = ProManager.shared
    let reason: String?
    let analyticsTrigger: String
    let analyticsSurface: String
    @State private var didTrackImpression = false

    init(
        reason: String? = nil,
        analyticsTrigger: String = "unknown",
        analyticsSurface: String = "paywall"
    ) {
        self.reason = reason
        self.analyticsTrigger = analyticsTrigger
        self.analyticsSurface = analyticsSurface
    }

    var body: some View {
        NavigationStack {
            ProUpsellContent(reason: reason, analyticsTrigger: analyticsTrigger, onPurchased: { dismiss() })
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
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
            if pro.isCrossPlatformPro { dismiss() }
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
                    hadMeaningfulReading: ProductAnalytics.shared.hadMeaningfulReading
                )
            )
        }
        .onChange(of: pro.isCrossPlatformPro) { isPro in if isPro { dismiss() } }
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
    var onPurchased: () -> Void = {}

    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var busy = false
    @State private var showLogin = false
    @State private var loadFailed = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""
    @State private var selectedProductID: String?

    private let benefits: [(String, String)] = [
        ("infinity", AppLocalized("无限朗读时长")),
        ("sparkles", AppLocalized("无限解读次数")),
        ("waveform", AppLocalized("全部高级音色")),
        ("hare.fill", AppLocalized("最高 3x 语速")),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if let reason, !reason.isEmpty { reasonBanner(reason) }
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
        .sheet(isPresented: $showLogin) { LoginView() }
        .alert("恢复购买", isPresented: $showRestoreAlert) {
            Button("好", role: .cancel) {}
        } message: { Text(restoreMessage) }
        .onAppear { Task { await reloadProducts(); syncDefaultSelection(); await pro.refresh() } }
        .onChange(of: pro.products.map(\.id)) { _ in syncDefaultSelection() }
        .task {
            if pro.isCrossPlatformPro { onPurchased() }
        }
        .onChange(of: pro.isCrossPlatformPro) { isPro in if isPro { onPurchased() } }
    }

    /// 默认选中年付。必须在 onAppear 也调一次：产品已缓存时 `onChange` 不会触发，
    /// 选择留在 nil 会让购买按钮一直是禁用的灰色状态，试用文案也不显示。
    private func syncDefaultSelection() {
        let ids = pro.products.map(\.id)
        guard selectedProductID == nil || !ids.contains(selectedProductID ?? "") else { return }
        selectedProductID = pro.products.first { $0.subscription?.subscriptionPeriod.unit == .year }?.id
            ?? pro.products.first?.id
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
                Text("登录邮箱同步 Pro").font(.caption.weight(.semibold))
            }
            Text("已检测到购买，请登录邮箱完成跨平台同步。")
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
                Label("已检测到购买，请登录邮箱同步 Pro", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundColor(AppTheme.primary)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(auth.hasSyncableAccount
                     ? AppLocalized("本机已解锁；跨平台同步等待 Apple 验证接口。")
                     : AppLocalized("本机已解锁；登录邮箱后可完成跨平台同步。"))
                    .font(.caption)
                    .foregroundColor(AppTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                if !auth.hasSyncableAccount {
                    Button("登录邮箱同步 Pro") { showLogin = true }
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
                ForEach(pro.products, id: \.id) { product in
                    Button {
                        selectedProductID = product.id
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName).fontWeight(.semibold)
                                Text(periodText(product)).font(.caption).opacity(0.85)
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
                Button {
                    // 只要求「已登录」：Apple 登录可能没有 email（仅首次授权返回），
                    // 手机号账号也没有 email；StoreKit 购买只要求已有账号身份，
                    // email / backend user id 只决定跨平台同步何时可用。
                    guard auth.isSignedIn else { showLogin = true; return }
                    guard let product = pro.products.first(where: { $0.id == selectedProductID }) else { return }
                    busy = true
                    Task { _ = await pro.purchase(product, analyticsTrigger: analyticsTrigger); busy = false }
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
        pro.products.first { $0.id == selectedProductID }
    }

    /// 有资格才显示试用天数；没资格的老用户走原有价格文案。
    private func trialDays(_ product: Product) -> Int? {
        guard pro.showsFreeTrial(for: product) else { return nil }
        return ProManager.freeTrialDays(for: product)
    }

    private var primaryCTATitle: String {
        guard let product = selectedProduct, let days = trialDays(product) else {
            return AppLocalized("升级到 CastReader Pro")
        }
        return String(format: AppLocalized("开始 %d 天免费试用"), days)
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
            return AppLocalized("已检测到购买，请登录邮箱同步 Pro")
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
