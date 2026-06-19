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
                Button("恢复购买") { Task { await pro.restore() } }
                    .font(.subheadline)
                accountRow
                termsRow
            }
            .padding(20)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showLogin) { LoginView() }
        .onAppear { Task { await pro.loadProducts(); await pro.refresh() } }
        .onChange(of: pro.isPro) { isPro in if isPro { onPurchased() } }
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
            Text("订阅自动续期，可随时在 App Store 取消。")
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
            ProgressView("加载订阅…")
        } else {
            VStack(spacing: 12) {
                ForEach(pro.products, id: \.id) { product in
                    Button {
                        busy = true
                        Task { _ = await pro.purchase(product); busy = false }
                    } label: {
                        HStack {
                            Text(product.displayName).fontWeight(.semibold)
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
}
