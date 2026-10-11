import SwiftUI
import StoreKit

struct CloneCreditPurchaseView: View {
    @ObservedObject private var interfaceLanguage = AppLanguageManager.shared

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readerScene: ReaderSceneContext
    @ObservedObject var store: CloneCreditStore = .shared
    @ObservedObject private var access = VoiceCloneAccessCoordinator.shared
    var fromQuotaExhaustion = false

    @State private var showsRules = false
    @State private var showsPro = false

    private var exhausted: Bool { store.currentBalance?.isExhausted == true }
    private var available: Int? {
        guard store.currentBalance?.enabled == true else { return nil }
        return store.currentBalance?.availableMs
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    balanceHeader
                    purchaseCard
                    if let message = store.message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedForeground)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("cloneCreditMessage")
                    }
                    if fromQuotaExhaustion, access.hasCreditWaiters,
                       store.currentBalance?.canApply == true {
                        Button(AppLocalized("继续朗读或解读")) {
                            access.continueAfterCreditPurchase(store: store)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isSyncing || store.isPurchasing)
                        .accessibilityIdentifier("cloneCreditContinue")
                    }
                    DisclosureGroup(isExpanded: $showsRules) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(AppLocalized("每月 120 分钟基础额度，用完后可使用加购额度。"))
                            Text(AppLocalized("加购额度长期有效，优先使用每月基础额度。仅 Pro 会员可购买及使用；Pro 到期后保留加购余额。"))
                            Text(AppLocalized("按成功生成的音频时长计量；试听和重复播放已生成的音频不扣额度。"))
                        }
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .padding(.top, 12)
                    } label: {
                        Text(AppLocalized("额度说明")).font(.subheadline)
                    }
                    .accessibilityIdentifier("cloneCreditRules")
                    Button(AppLocalized("同步余额与待到账购买")) { Task { await store.recover() } }
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .disabled(store.isSyncing || store.isPurchasing)
                        .accessibilityIdentifier("cloneCreditRecover")
                }
                .padding(28)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background)
            .navigationTitle(AppLocalized("克隆音色额度"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("完成")) { dismiss() }
                        .accessibilityIdentifier("cloneCreditClose")
                }
            }
            .task { await store.recover() }
            .sheet(isPresented: $showsPro) { PaywallView() }
        }
        .environment(\.layoutDirection, interfaceLanguage.selectedLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
        #if targetEnvironment(macCatalyst)
        .frame(width: 560, height: 660)
        #endif
    }

    private var balanceHeader: some View {
        VStack(spacing: 14) {
            Image(systemName: exhausted ? "waveform.badge.exclamationmark" : "waveform")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(AppTheme.primary)
                .frame(width: 64, height: 64)
                .background(AppTheme.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
            if exhausted {
                Text(AppLocalized("生成额度已用完"))
                    .font(.title2.bold())
                    .accessibilityIdentifier("cloneCreditExhausted")
            } else {
                Text(AppLocalized("当前可用"))
                    .font(.subheadline).foregroundStyle(AppTheme.mutedForeground)
                Text(Self.balanceText(available))
                    .font(available == nil ? .title3 : .system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityIdentifier("cloneCreditAvailable")
            }
            if let balance = store.currentBalance, balance.enabled {
                HStack(spacing: 0) {
                    balanceBucket("本月基础剩余", milliseconds: balance.baseRemainingMs)
                    Rectangle().fill(AppTheme.mutedForeground.opacity(0.2)).frame(width: 1, height: 36)
                    balanceBucket("加购剩余", milliseconds: balance.purchasedRemainingMs)
                }
                .padding(.vertical, 16)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("cloneCreditBalance")
                if let raw = balance.baseResetAt,
                   let date = ISO8601DateFormatter().date(from: raw) ?? Self.fractionalDate(raw) {
                    Text(String(format: AppLocalized("下次更新：%@"), date.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguageManager.shared.locale))))
                        .font(.caption).foregroundStyle(AppTheme.mutedForeground)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func balanceBucket(_ title: String.LocalizationValue, milliseconds: Int?) -> some View {
        VStack(spacing: 6) {
            Text(AppLocalized(title)).font(.caption).foregroundStyle(AppTheme.mutedForeground)
            Text(Self.balanceText(milliseconds)).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private var purchaseCard: some View {
        VStack(spacing: 16) {
            Label(AppLocalized("增加 120 分钟"), systemImage: "plus.circle.fill")
                .font(.title3.bold())
            if store.currentBalance?.canPurchase == false {
                Text(AppLocalized("Pro 会员可以购买更多克隆音色额度"))
                    .font(.subheadline).foregroundStyle(AppTheme.mutedForeground)
                Button(AppLocalized("升级 Pro")) { showsPro = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("cloneCreditUpgrade")
            } else {
                Button {
                    Task { await store.purchase(in: readerScene.window?.windowScene) }
                } label: {
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        if store.isPurchasing || store.isSyncing { ProgressView().tint(.white) }
                        Text(store.product.map { String(format: AppLocalized("购买 · %@"), $0.displayPrice) }
                             ?? AppLocalized("正在加载价格…"))
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 14))
                    .opacity(store.product == nil || store.currentBalance?.canPurchase != true
                             || store.hasPendingDelivery ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .controlSize(.large)
                .disabled(store.product == nil || store.currentBalance?.canPurchase != true
                          || store.isPurchasing || store.hasPendingDelivery)
                .accessibilityIdentifier("cloneCreditPurchase")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(AppTheme.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.primary.opacity(0.18)))
    }

    private static func fractionalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    static func duration(_ milliseconds: Int) -> String {
        if milliseconds > 0 && milliseconds < 60_000 { return AppLocalized("不足 1 分钟") }
        return String(format: AppLocalized("%lld 分钟"), Int64(max(0, milliseconds) / 60_000))
    }

    static func balanceText(_ milliseconds: Int?) -> String {
        milliseconds.map(duration) ?? AppLocalized("生成额度正在同步")
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Uses a seeded disposable account and loopback server only. Production builds
/// never contain this entry point or the test credential.
struct CloneCreditAcceptanceFixture: View {
    @StateObject private var store: CloneCreditStore
    init() {
        let owner = "clone-simulator-ui"
        let client = CloneCreditClient(baseURL: URL(string: "http://127.0.0.1:55446")!,
            token: { "cms_\(owner)_local_fixture_session_token" }, refreshToken: { nil })
        _store = StateObject(wrappedValue: CloneCreditStore(client: client, account: { owner }, hasPro: { true }))
    }
    var body: some View {
        CloneCreditPurchaseView(store: store)
            .task { store.start() }
    }
}
#endif
