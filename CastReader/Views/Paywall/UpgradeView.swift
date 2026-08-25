//
//  UpgradeView.swift
//  CastReader
//
//  从设置进入的 Pro 升级页（复用 ProUpsellContent）。
//

import SwiftUI
import StoreKit

struct UpgradeView: View {
    @ObservedObject private var pro = ProManager.shared
    @State private var selectedProductID: String?
    @State private var didTrackImpression = false
    @State private var didCompletePurchase = false
    @State private var didTrackDismissal = false

    private let analyticsTrigger = "settings_upgrade"
    private let analyticsSurface = "settings"

    var body: some View {
        ProUpsellContent(
            analyticsTrigger: analyticsTrigger,
            analyticsSurface: analyticsSurface,
            onPurchased: { didCompletePurchase = true },
            onSelectionChanged: { selectedProductID = $0 }
        )
            .navigationTitle("升级 Pro")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { trackImpressionIfNeeded() }
            .onChange(of: pro.isCrossPlatformPro) { _, isPro in
                if isPro { didCompletePurchase = true }
            }
            .onDisappear { trackDismissalIfNeeded() }
    }

    private func trackImpressionIfNeeded() {
        guard !didTrackImpression else { return }
        didTrackImpression = true
        let product = selectedProduct ?? defaultProduct
        ProductAnalytics.shared.track(
            .paywallShown,
            context: .init(
                productArea: .billing,
                surface: analyticsSurface,
                entryPoint: analyticsTrigger
            ),
            properties: .init(
                trigger: analyticsTrigger,
                entitlementState: entitlementState,
                hadMeaningfulReading: ProductAnalytics.shared.hadMeaningfulReading,
                configId: GrowthLoopConversionCoordinator.shared.activeConfigID,
                offerEligible: product.map { pro.showsFreeTrial(for: $0) },
                selectedProductId: product?.id
            )
        )
    }

    private func trackDismissalIfNeeded() {
        guard didTrackImpression,
              !didCompletePurchase,
              !pro.isCrossPlatformPro,
              !didTrackDismissal else { return }
        didTrackDismissal = true
        let product = selectedProduct ?? defaultProduct
        let offerEligible = product.map { pro.showsFreeTrial(for: $0) }
        ProductAnalytics.shared.trackPaywallAction(
            productId: product?.id ?? "unknown",
            action: .dismissed,
            trigger: analyticsTrigger,
            surface: analyticsSurface,
            offerEligible: offerEligible,
            trialDays: product.flatMap {
                offerEligible == true ? ProManager.freeTrialDays(for: $0) : nil
            }
        )
    }

    private var selectedProduct: Product? {
        pro.displayProducts.first { $0.id == selectedProductID }
    }

    private var defaultProduct: Product? {
        pro.displayProducts.first {
            $0.subscription?.subscriptionPeriod.unit == .year
        } ?? pro.displayProducts.first
    }

    private var entitlementState: String {
        if pro.isCrossPlatformPro { return "pro" }
        if pro.storeKitLocalPro { return "storekit_local_only" }
        if pro.serverPro { return "server_pro" }
        return "free"
    }
}
