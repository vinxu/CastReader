//
//  GrowthTrialOfferOverlay.swift
//  CastReader
//
//  A non-blocking value-moment offer. It deliberately sits above both native
//  and Kindle readers, while the hard five-minute gate remains a full paywall.
//

import StoreKit
import SwiftUI

struct GrowthTrialOfferOverlay: View {
    @ObservedObject var coordinator: GrowthLoopConversionCoordinator
    let onPreview: (GrowthTrialOffer) -> Void

    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var appLanguage = AppLanguageManager.shared

    var body: some View {
        if let offer = coordinator.softOffer, !pro.isPro {
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.primary)
                            .frame(width: 40, height: 40)
                            .background(AppTheme.primary.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalized("已为你准备好"))
                                .font(.headline)
                                .foregroundStyle(AppTheme.foreground)
                            if let title = offer.documentTitle, !title.isEmpty {
                                Text(title)
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.mutedForeground)
                                    .lineLimit(1)
                            } else {
                                Text(offerSubtitle(offer))
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.mutedForeground)
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: 4)

                        Button {
                            coordinator.dismissSoftOffer()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.mutedForeground)
                                .frame(width: 30, height: 30)
                                .background(AppTheme.surfaceVariant, in: Circle())
                        }
                        .accessibilityLabel(AppLocalized("关闭"))
                    }

                    HStack(spacing: 10) {
                        Button {
                            coordinator.presentPaywall(
                                from: offer,
                                postPurchasePreview: { onPreview(offer) }
                            )
                        } label: {
                            Text(primaryTitle)
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.primary)
                        .accessibilityIdentifier("growthTrialOfferPrimary")

                        Button {
                            coordinator.dismissSoftOffer()
                            onPreview(offer)
                        } label: {
                            Text(offer.milestone == .libraryReady
                                 ? AppLocalized("试听")
                                 : AppLocalized("稍后"))
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 68, minHeight: 42)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.primary)
                        .accessibilityIdentifier("growthTrialOfferPreview")
                    }
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AppTheme.border.opacity(0.8), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.16), radius: 18, y: 8)
                .padding(.horizontal, 16)
                .padding(.bottom, 104)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.36, dampingFraction: 0.88), value: offer.id)
            .onAppear {
                coordinator.noteOfferRendered(offer)
            }
            .id("\(offer.id)-\(appLanguage.selectedLanguage.rawValue)")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("growthTrialOffer")
        }
    }

    private var eligibleTrialProduct: Product? {
        let defaultProduct = pro.displayProducts.first(where: {
            $0.subscription?.subscriptionPeriod.unit == .year
        }) ?? pro.displayProducts.first
        guard let defaultProduct, pro.showsFreeTrial(for: defaultProduct) else { return nil }
        return defaultProduct
    }

    /// Trial wording is derived only from StoreKit's live eligibility result.
    /// Missing products or an ineligible Apple ID get neutral Pro copy.
    private var primaryTitle: String {
        guard let product = eligibleTrialProduct,
              let days = ProManager.freeTrialDays(for: product) else {
            return AppLocalized("查看 Pro 方案")
        }
        return String(format: AppLocalized("开始 %d 天免费试用"), days)
    }

    private func offerSubtitle(_ offer: GrowthTrialOffer) -> String {
        switch offer.milestone {
        case .libraryReady:
            return AppLocalized("先听 30 秒，看看 CastReader 怎么读")
        case .listened30Seconds:
            return AppLocalized("解锁完整朗读、解读与高级声音体验")
        }
    }
}
