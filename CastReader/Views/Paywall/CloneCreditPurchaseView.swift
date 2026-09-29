import SwiftUI
import StoreKit

struct CloneCreditPurchaseView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readerScene: ReaderSceneContext
    @ObservedObject var store: CloneCreditStore = .shared
    @ObservedObject private var access = VoiceCloneAccessCoordinator.shared
    var fromQuotaExhaustion = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "waveform.badge.plus").font(.largeTitle).foregroundStyle(AppTheme.primary)
                        Text(AppLocalized(fromQuotaExhaustion ? "生成额度已用完" : "更多克隆音色额度"))
                            .font(.title2.bold())
                        Text(AppLocalized("每月 120 分钟基础额度，用完后可使用加购额度。"))
                            .font(.subheadline).foregroundStyle(AppTheme.mutedForeground)
                    }
                    if let balance = store.currentBalance, balance.enabled {
                        VStack(spacing: 14) {
                            row("本月基础剩余", milliseconds: balance.baseRemainingMs)
                            row("加购剩余", milliseconds: balance.purchasedRemainingMs)
                            Divider()
                            row("当前可用", milliseconds: balance.availableMs)
                            if let raw = balance.baseResetAt,
                               let date = ISO8601DateFormatter().date(from: raw)
                                ?? Self.fractionalDate(raw) {
                                Text(String(format: AppLocalized("下次更新：%@"), date.formatted(date: .abbreviated, time: .omitted)))
                                    .font(.caption).foregroundStyle(AppTheme.mutedForeground)
                            }
                        }
                        .padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("cloneCreditBalance")
                    } else {
                        Text(AppLocalized("生成额度正在同步")).foregroundStyle(AppTheme.mutedForeground)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(AppLocalized("增加 120 分钟")).font(.headline)
                        Text(AppLocalized("加购额度长期有效，优先使用每月基础额度。仅 Pro 会员可购买及使用；Pro 到期后保留加购余额。"))
                            .font(.footnote).foregroundStyle(AppTheme.mutedForeground)
                        Button {
                            Task { await store.purchase(in: readerScene.window?.windowScene) }
                        } label: {
                            HStack {
                                Spacer()
                                if store.isPurchasing || store.isSyncing { ProgressView().tint(.white) }
                                Text(store.product.map { String(format: AppLocalized("购买 · %@"), $0.displayPrice) }
                                     ?? AppLocalized("正在加载价格…"))
                                    .font(.headline)
                                Spacer()
                            }.padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.product == nil || store.currentBalance?.canPurchase != true
                                  || store.isPurchasing || store.hasPendingDelivery)
                        .accessibilityIdentifier("cloneCreditPurchase")
                        if store.currentBalance?.canPurchase == false {
                            Text(AppLocalized("Pro 会员可以购买更多克隆音色额度"))
                                .font(.footnote).foregroundStyle(AppTheme.mutedForeground)
                        }
                    }
                    if let message = store.message {
                        Text(message).font(.subheadline).accessibilityIdentifier("cloneCreditMessage")
                    }
                    if fromQuotaExhaustion, access.hasCreditWaiters {
                        Button(AppLocalized("继续朗读或解读")) {
                            access.continueAfterCreditPurchase(store: store)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.currentBalance?.canApply != true || store.isSyncing || store.isPurchasing)
                        .accessibilityIdentifier("cloneCreditContinue")
                    }
                    Button(AppLocalized("同步余额与待到账购买")) { Task { await store.recover() } }
                        .disabled(store.isSyncing || store.isPurchasing)
                        .accessibilityIdentifier("cloneCreditRecover")
                    Text(AppLocalized("按成功生成的音频时长计量；试听和重复播放已生成的音频不扣额度。"))
                        .font(.footnote).foregroundStyle(AppTheme.mutedForeground)
                }.padding(24)
            }
            .background(AppTheme.background)
            .navigationTitle(AppLocalized("克隆音色额度"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("完成")) { dismiss() } } }
            .task { await store.recover() }
        }
    }

    private func row(_ title: String.LocalizationValue, milliseconds: Int?) -> some View {
        HStack {
            Text(AppLocalized(title))
            Spacer()
            Text(milliseconds.map(Self.duration) ?? "—").monospacedDigit()
        }.font(.subheadline)
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
