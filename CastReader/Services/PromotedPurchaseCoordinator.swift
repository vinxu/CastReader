import Foundation
import StoreKit
import SwiftUI
import UIKit
import Combine

/// A restored request only restores the confirmation page, never a payment.
struct PromotedPurchaseRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let productID: String
    let receivedAt: Date
    let accountID: String?

    func isUsable(at date: Date, accountID currentAccount: String?) -> Bool {
        let age = date.timeIntervalSince(receivedAt)
        return age >= 0 && age < 24 * 60 * 60
            && (accountID == nil || currentAccount == nil || accountID == currentAccount)
    }
}

@MainActor
final class PromotedPurchaseCoordinator: ObservableObject {
    static let shared = PromotedPurchaseCoordinator()
    private let defaults: UserDefaults
    private let storageKey = "castreader.promotedPurchase.pending.v1"
    private var listener: Task<Void, Never>?
    private var presentationTimer: AnyCancellable?
    private var retainedProducts: [String: Product] = [:]
    private var loadingProduct = false
    private weak var presentedController: UIViewController?
    private var presentedRequest: PromotedPurchaseRequest?
    private var presentedAccountBoundary: UUID?
    private var failedRequestID: UUID?
    private(set) var pending: PromotedPurchaseRequest?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey) {
            pending = try? JSONDecoder().decode(PromotedPurchaseRequest.self, from: data)
        }
    }

    func start() {
        guard listener == nil else { return }
        #if !targetEnvironment(macCatalyst)
        listener = Task { [weak self] in
            for await intent in PurchaseIntent.intents {
                guard !Task.isCancelled else { return }
                self?.receive(intent.product)
            }
        }
        // UI may not exist when StoreKit delivers a cold-launch intent. Polling
        // only the presentation boundary also lets existing alerts finish first.
        presentationTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in
                Task { @MainActor in await self?.presentIfPossible() }
            }
        #endif
    }

    @discardableResult
    func enqueue(productID: String, accountID: String?, at date: Date = Date()) -> Bool {
        guard ProManager.productIDs.contains(productID) else { return false }
        if let active = presentedRequest, active.productID == productID,
           presentedController?.presentingViewController != nil { return false }
        if let pending, pending.productID == productID,
           pending.isUsable(at: date, accountID: accountID) { return false }
        failedRequestID = nil
        pending = .init(id: UUID(), productID: productID, receivedAt: date, accountID: accountID)
        persist()
        return true
    }

    func discardPending() {
        if let pending { retainedProducts.removeValue(forKey: pending.productID) }
        pending = nil
        failedRequestID = nil
        persist()
    }

    private func receive(_ product: Product) {
        guard ProManager.productIDs.contains(product.id) else { return }
        retainedProducts[product.id] = product
        _ = enqueue(productID: product.id, accountID: AuthService.shared.proUserId)
        Task { await presentIfPossible() }
    }

    private func persist() {
        if let pending, let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func showLoadFailure(for request: PromotedPurchaseRequest, from presenter: UIViewController) {
        guard pending?.id == request.id, presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil, !presenter.isBeingDismissed else { return }
        failedRequestID = request.id
        let alert = UIAlertController(title: AppLocalized("订阅信息加载失败"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: AppLocalized("重试"), style: .default) { [weak self] _ in
            self?.failedRequestID = nil
        })
        alert.addAction(UIAlertAction(title: AppLocalized("取消"), style: .cancel) { [weak self] _ in
            if self?.pending?.id == request.id { self?.discardPending() }
        })
        presenter.present(alert, animated: true)
    }

    private func presentIfPossible() async {
        let auth = AuthService.shared
        if let active = presentedRequest {
            if !auth.isSignedIn || auth.accountBoundaryID != presentedAccountBoundary {
                presentedController?.dismiss(animated: false)
                presentedController = nil
                presentedRequest = nil
                presentedAccountBoundary = nil
                if pending?.id == active.id { discardPending() }
            } else if presentedController?.presentingViewController == nil {
                // Interactive dismissal, Close, and successful completion all
                // consume this request. A later StoreKit intent can open again.
                presentedController = nil
                presentedRequest = nil
                presentedAccountBoundary = nil
                if pending?.id == active.id { discardPending() }
            } else { return }
        }
        guard let request = pending else { return }
        guard request.isUsable(at: Date(), accountID: auth.proUserId) else {
            discardPending(); return
        }
        guard auth.isSignedIn, !ProManager.shared.purchaseInProgress,
              let scene = ReaderSceneRegistry.shared.presentationContext,
              let window = scene.window, window.isKeyWindow,
              window.windowScene?.activationState == .foregroundActive,
              var presenter = window.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIAlertController), !presenter.isBeingDismissed,
              !presenter.isBeingPresented, presenter.viewIfLoaded?.window != nil else { return }
        guard !loadingProduct, failedRequestID != request.id else { return }
        let product: Product
        if let retained = retainedProducts[request.productID] { product = retained }
        else {
            loadingProduct = true
            defer { loadingProduct = false }
            do {
                guard let loaded = try await Product.products(for: [request.productID]).first else {
                    showLoadFailure(for: request, from: presenter); return
                }
                retainedProducts[request.productID] = loaded
            } catch { showLoadFailure(for: request, from: presenter); return }
            // Check scene/account again after asynchronous StoreKit lookup.
            return
        }
        guard pending?.id == request.id else { return }
        let view = PaywallView(
            analyticsTrigger: "app_store_promotion",
            analyticsSurface: "promoted_purchase",
            promotedProduct: product
        )
        .environmentObject(scene)
        .environment(\.locale, AppLanguageManager.shared.locale)
        .environment(\.layoutDirection, AppLanguageManager.shared.selectedLanguage.isRightToLeft ? .rightToLeft : .leftToRight)
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .formSheet
        presentedRequest = request
        presentedAccountBoundary = auth.accountBoundaryID
        presentedController = controller
        presenter.present(controller, animated: true)
    }
}
