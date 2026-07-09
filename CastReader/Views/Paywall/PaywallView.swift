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

    var body: some View {
        NavigationView {
            ProUpsellContent(onPurchased: { dismiss() })
                .navigationTitle("CastReader Pro")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .task {
            if pro.isPro { dismiss() }
        }
        .onChange(of: pro.isPro) { isPro in if isPro { dismiss() } }
    }
}

/// Pro 权益 + 购买按钮（PaywallView 与 UpgradeView 共用）。
struct ProUpsellContent: View {
    var onPurchased: () -> Void = {}

    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var busy = false
    @State private var showLogin = false
    @State private var loadFailed = false
    @State private var showRestoreAlert = false
    @State private var restoreMessage = ""

    private let benefits: [(String, String)] = [
        ("infinity", String(localized: "无限朗读时长")),
        ("sparkles", String(localized: "无限解读次数")),
        ("waveform", String(localized: "全部高级音色")),
        ("hare.fill", String(localized: "最高 3x 语速")),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                benefitList
                buySection
                Button("恢复购买") {
                    Task {
                        busy = true
                        await pro.restore()
                        busy = false
                        restoreMessage = pro.isPro ? String(localized: "已恢复 Pro 会员") : String(localized: "未找到可恢复的购买")
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
        .onAppear { Task { await reloadProducts(); await pro.refresh() } }
        .task {
            if pro.isPro { onPurchased() }
        }
        .onChange(of: pro.isPro) { isPro in if isPro { onPurchased() } }
    }

    /// 加载产品；加载后仍为空标记 loadFailed，供付费墙显示「重试」而非永久转圈。
    private func reloadProducts() async {
        loadFailed = false
        await pro.loadProducts()
        loadFailed = pro.products.isEmpty
    }

    @ViewBuilder
    private var accountRow: some View {
        if let acc = auth.account {
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
            Image(systemName: "crown.fill")
                .font(.system(size: 44)).foregroundColor(AppTheme.primary)
            Text("CastReader Pro").font(.title2.weight(.bold))
            Text("解锁全部朗读与解读能力")
                .font(.subheadline).foregroundColor(AppTheme.mutedForeground)
        }
        .padding(.top, 12)
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
        .cornerRadius(16)
    }

    @ViewBuilder
    private var buySection: some View {
        if pro.isPro {
            Label("你已是 Pro 会员", systemImage: "checkmark.seal.fill")
                .foregroundColor(.green).font(.headline)
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
            VStack(spacing: 12) {
                ForEach(pro.products, id: \.id) { product in
                    Button {
                        busy = true
                        Task { _ = await pro.purchase(product); busy = false }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName).fontWeight(.semibold)
                                Text(periodText(product)).font(.caption).opacity(0.85)
                            }
                            Spacer()
                            Text(product.displayPrice).fontWeight(.bold)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(AppTheme.primary)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(busy)
                }
            }
        }
    }

    /// 订阅周期文案（满足 Apple 3.1.2：购买点附近明示订阅时长）。
    private func periodText(_ p: Product) -> String {
        switch p.subscription?.subscriptionPeriod.unit {
        case .month: return String(localized: "按月订阅")
        case .year: return String(localized: "按年订阅")
        case .week: return String(localized: "按周订阅")
        case .day: return String(localized: "按天订阅")
        default: return ""
        }
    }
}
