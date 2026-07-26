//
//  HomeProUpsellCard.swift
//  CastReader
//
//  Compact home conversion card. The artwork is deliberately text-free so
//  every visible word can follow the app's nine-language runtime bundle.
//

import StoreKit
import SwiftUI
import UIKit

enum HomeProPrimaryAction: Equatable {
    case none
    case requireLogin
    case purchaseYearly
    case showPlans
}

enum HomeProPurchaseContract {
    static func primaryAction(
        isPro: Bool,
        hasYearlyProduct: Bool,
        hasEmailAccount: Bool,
        isLoadingProducts: Bool,
        isPurchaseInFlight: Bool
    ) -> HomeProPrimaryAction {
        guard !isPro, !isPurchaseInFlight else { return .none }
        if isLoadingProducts { return .none }
        guard hasYearlyProduct else { return .showPlans }
        return hasEmailAccount ? .purchaseYearly : .requireLogin
    }
}

enum HomeProPricing {
    static func weeklyPrice(from yearlyPrice: Decimal) -> Decimal {
        yearlyPrice / Decimal(52)
    }

    static func weeklyDisplayPrice(for product: Product) -> String {
        weeklyPrice(from: product.price).formatted(product.priceFormatStyle)
    }
}

struct HomeProUpsellCard: View {
    let annualDisplayPrice: String?
    let weeklyDisplayPrice: String?
    let isLoadingProducts: Bool
    let isPurchasing: Bool
    let onPrimaryAction: () -> Void
    let onShowPlans: () -> Void

    @ObservedObject private var appLanguage = AppLanguageManager.shared

    private var annualPriceText: String {
        guard let annualDisplayPrice else {
            return isLoadingProducts ? AppLocalized("正在加载价格") : AppLocalized("价格暂不可用")
        }
        return String(format: AppLocalized("%@/年"), annualDisplayPrice)
    }

    private var weeklyPriceText: String? {
        guard let weeklyDisplayPrice else { return nil }
        return String(format: AppLocalized("折合约 %@/周"), weeklyDisplayPrice)
    }

    private var primaryTitle: String {
        if isPurchasing { return AppLocalized("正在连接 App Store…") }
        guard let annualDisplayPrice else {
            return isLoadingProducts ? AppLocalized("正在加载价格") : AppLocalized("查看 Pro 方案")
        }
        return String(format: AppLocalized("以 %@/年成为 Pro"), annualDisplayPrice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeProBookArtwork()
                .frame(height: 108)
                .accessibilityHidden(true)

            Text("CASTREADER PRO")
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundColor(AppTheme.primary)

            Text(AppLocalized("让每本 Kindle 都开口说话"))
                .font(.title2.weight(.bold))
                .foregroundColor(AppTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            Text(AppLocalized("Kindle 连续朗读 · 100+ 专业音色 · 9 种语言"))
                .font(.subheadline)
                .foregroundColor(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(annualPriceText)
                    .font(.title3.weight(.bold))
                    .foregroundColor(AppTheme.foreground)
                    .contentTransition(.numericText())

                if let weeklyPriceText {
                    Text(weeklyPriceText)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.mutedForeground)
                        .contentTransition(.numericText())
                }
            }
            .accessibilityElement(children: .combine)

            Button(action: onPrimaryAction) {
                HStack(spacing: 9) {
                    if isPurchasing {
                        ProgressView().tint(AppTheme.primaryForeground)
                    }
                    Text(primaryTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .padding(.horizontal, 12)
                .foregroundColor(AppTheme.primaryForeground)
                .background(AppTheme.primary, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLoadingProducts || isPurchasing)
            .opacity(isLoadingProducts ? 0.68 : 1)
            .accessibilityIdentifier("homeProYearlyButton")

            Button(action: onShowPlans) {
                Text(AppLocalized("月度方案与恢复购买"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.foreground)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.plain)
            .disabled(isPurchasing)
            .accessibilityIdentifier("homeProPlansButton")

            Text(AppLocalized("按年自动续订，可随时取消"))
                .font(.caption2)
                .foregroundColor(AppTheme.mutedForeground)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .padding(17)
        .background(AppTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border.opacity(0.82), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("homeProUpsellCard")
        .id(appLanguage.selectedLanguage.rawValue)
    }
}

private struct HomeProBookArtwork: View {
    private struct Cover: Identifiable {
        let id: Int
        let imageName: String
        let width: CGFloat
        let height: CGFloat
        let rotation: Double
        let x: CGFloat
        let y: CGFloat
    }

    private let covers: [Cover] = [
        .init(id: 0, imageName: "home-pro-dracula", width: 54, height: 81, rotation: -9, x: -108, y: 9),
        .init(id: 1, imageName: "home-pro-alice", width: 58, height: 87, rotation: -4, x: -57, y: 3),
        .init(id: 2, imageName: "home-pro-pride", width: 64, height: 96, rotation: 0, x: 0, y: -1),
        .init(id: 3, imageName: "home-pro-moby-dick", width: 58, height: 87, rotation: 4, x: 58, y: 3),
        .init(id: 4, imageName: "home-pro-frankenstein", width: 54, height: 81, rotation: 9, x: 109, y: 9),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.surface.opacity(0.58))

                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(AppTheme.primary.opacity(0.07))
                    .frame(width: min(proxy.size.width * 0.88, 304), height: 62)
                    .offset(y: 28)

                ForEach(covers) { cover in
                    coverImage(named: cover.imageName)
                        .frame(width: cover.width, height: cover.height)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.42), lineWidth: 0.7)
                        )
                        .shadow(color: AppTheme.foreground.opacity(0.18), radius: 5, x: 0, y: 4)
                        .rotationEffect(.degrees(cover.rotation))
                        .offset(x: cover.x, y: cover.y)
                }
            }
        }
    }

    @ViewBuilder
    private func coverImage(named imageName: String) -> some View {
        if let url = Bundle.main.url(forResource: imageName, withExtension: "jpg"),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                AppTheme.surface
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(AppTheme.primary)
            }
        }
    }
}
