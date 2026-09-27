import Foundation
import StoreKit
import Combine
import UIKit

struct CloneCreditBalance: Decodable, Equatable, Sendable {
    let enabled: Bool
    let revision: Int?
    let environment: String?
    let productId: String?
    let baseLimitMs: Int?
    let baseRemainingMs: Int?
    let baseReservedMs: Int?
    let baseResetAt: String?
    let purchasedRemainingMs: Int?
    let purchasedReservedMs: Int?
    let availableMs: Int?
    let canApply: Bool?
    let canPurchase: Bool
    let delivery: Delivery?

    struct Delivery: Decodable, Equatable, Sendable {
        let transactionId: String
        let credited: Bool
        let refunded: Bool
    }
}

enum CloneCreditFailure: LocalizedError {
    case unavailable, signedOut, proRequired, unverified, accountChanged
    var errorDescription: String? {
        switch self {
        case .unavailable: return AppLocalized("额度暂时无法同步，请稍后重试。已付款的订单会自动补到账。")
        case .signedOut: return AppLocalized("请先登录后购买额度")
        case .proRequired: return AppLocalized("Pro 会员可以购买更多克隆音色额度")
        case .unverified: return AppLocalized("购买正在验证，请稍后重试")
        case .accountChanged: return AppLocalized("账号已切换，请回到购买时的账号同步额度")
        }
    }
}

actor CloneCreditClient {
    private let baseURL: URL
    private let session: URLSession
    private let token: @Sendable () async -> String?
    private let refreshToken: @Sendable () async -> String?

    init(baseURL: URL? = nil, session: URLSession = OwnedAPIURLSession.shared,
         token: @escaping @Sendable () async -> String? = { await MobileSessionStore.shared.sessionToken() },
         refreshToken: @escaping @Sendable () async -> String? = { await MobileSessionStore.shared.refreshSession() }) {
        self.baseURL = baseURL ?? Self.endpointBaseURL
        self.session = session
        self.token = token
        self.refreshToken = refreshToken
    }

    nonisolated static var endpointBaseURL: URL {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-CastReaderCloneCreditsBaseURL"), arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1]), url.scheme == "http", url.host == "127.0.0.1" {
            return url
        }
        #endif
        return URL(string: Constants.API.webURL)!
    }

    func request(signedTransaction: String? = nil, environment: String = "Production", canRefreshSession: Bool = true) async throws -> CloneCreditBalance {
        var credential = await token()
        if credential == nil, canRefreshSession { credential = await refreshToken() }
        guard let token = credential, !token.isEmpty else { throw CloneCreditFailure.signedOut }
        let path = signedTransaction == nil ? "api/voice-clone/credits" : "api/voice-clone/credits/verify-apple"
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        request.setValue(environment, forHTTPHeaderField: "X-Clone-Billing-Environment")
        if let signedTransaction {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["signedTransaction": signedTransaction])
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloneCreditFailure.unavailable }
        if http.statusCode == 401, canRefreshSession, await refreshToken() != nil {
            return try await self.request(signedTransaction: signedTransaction, environment: environment, canRefreshSession: false)
        }
        guard http.statusCode != 401 else { throw CloneCreditFailure.signedOut }
        guard (200..<300).contains(http.statusCode) else { throw CloneCreditFailure.unavailable }
        struct Envelope: Decodable { let code: Int; let data: CloneCreditBalance }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.code == 0 else { throw CloneCreditFailure.unavailable }
        return envelope.data
    }
}

@MainActor
final class CloneCreditStore: ObservableObject {
    static let shared = CloneCreditStore()
    static let productID = "ai.castreader.clone.minutes120"
    @Published private(set) var balance: CloneCreditBalance?
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    @Published private(set) var isSyncing = false
    @Published private(set) var message: String?
    @Published private(set) var hasPendingDelivery = false

    private let client: CloneCreditClient
    private let account: @MainActor () -> String?
    private let hasPro: @MainActor () -> Bool
    private var scope: String?
    private var sequence: UInt64 = 0
    private var listener: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var delivering = Set<UInt64>()
    private var pending = Set<UInt64>()
    private var observers = Set<AnyCancellable>()
    private var environment = "Production"

    init(client: CloneCreditClient = CloneCreditClient(),
         account: @escaping @MainActor () -> String? = { AuthService.shared.account?.backendUserId },
         hasPro: @escaping @MainActor () -> Bool = { ProManager.shared.isPro }) {
        self.client = client
        self.account = account
        self.hasPro = hasPro
    }

    deinit { listener?.cancel(); retryTask?.cancel() }

    var availableMs: Int? { currentBalance?.availableMs }
    var currentBalance: CloneCreditBalance? { scope == account() ? balance : nil }
    var billingEnvironment: String { scope == account() ? environment : "Production" }

    func start() {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.deliver(verification)
            }
        }
        AuthService.shared.$accountBoundaryID.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.resetScope()
                await self?.recover()
            }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor in await self?.recover() }
        }.store(in: &observers)
        Task { await recover() }
    }

    private func resetScope() {
        sequence &+= 1
        scope = account()
        balance = nil
        message = nil
        environment = scope.flatMap { UserDefaults.standard.string(forKey: "clone-credit-environment.\($0)") } ?? "Production"
        pending.removeAll()
        hasPendingDelivery = false
        retryTask?.cancel()
        retryTask = nil
    }

    func refresh() async {
        if scope != account() { resetScope() }
        guard let owner = account() else { return }
        sequence &+= 1
        let read = sequence
        do {
            async let products = Product.products(for: [Self.productID])
            let snapshot = try await client.request(environment: environment)
            let loadedProducts = try? await products
            guard owner == account(), read == sequence else { return }
            product = loadedProducts?.first
            apply(snapshot)
        } catch {
            guard owner == account(), read == sequence else { return }
            message = error.localizedDescription
        }
    }

    func recover() async {
        if scope != account() { resetScope() }
        guard account() != nil else { return }
        for await transaction in Transaction.unfinished { await deliver(transaction) }
        await refresh()
    }

    func purchase(in scene: UIWindowScene? = nil) async {
        guard !isPurchasing, !hasPendingDelivery else { return }
        if scope != account() { resetScope() }
        guard let owner = account() else { message = CloneCreditFailure.signedOut.localizedDescription; return }
        guard hasPro() else { message = CloneCreditFailure.proRequired.localizedDescription; return }
        isPurchasing = true
        defer { isPurchasing = false }
        message = nil
        await refresh()
        guard owner == account(), hasPro(), currentBalance?.canPurchase == true,
              let product else { message = CloneCreditFailure.unavailable.localizedDescription; return }
        do {
            let options: Set<Product.PurchaseOption> = [.appAccountToken(ProManager.accountBoundAppAccountToken(userId: owner))]
            let result: Product.PurchaseResult
            if let scene { result = try await product.purchase(confirmIn: scene, options: options) }
            else { result = try await product.purchase(options: options) }
            switch result {
            case .success(let verification): await deliver(verification)
            case .pending: message = AppLocalized("购买等待批准，批准后额度会自动到账")
            case .userCancelled: message = nil
            @unknown default: message = CloneCreditFailure.unavailable.localizedDescription
            }
        } catch StoreKitError.userCancelled { message = nil }
          catch { message = error.localizedDescription }
    }

    @discardableResult
    func deliver(_ verification: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let transaction) = verification else {
            if case .unverified(let transaction, _) = verification, transaction.productID == Self.productID {
                message = CloneCreditFailure.unverified.localizedDescription
            }
            return false
        }
        guard transaction.productID == Self.productID else { return false }
        guard let owner = account(), transaction.appAccountToken == ProManager.accountBoundAppAccountToken(userId: owner) else { return false }
        guard delivering.insert(transaction.id).inserted else { return false }
        defer { delivering.remove(transaction.id) }
        isSyncing = true
        defer { isSyncing = !delivering.subtracting([transaction.id]).isEmpty }
        pending.insert(transaction.id)
        hasPendingDelivery = true
        message = AppLocalized("购买成功，正在同步额度…")
        sequence &+= 1 // Older reads cannot cover a credited balance.
        do {
            let snapshot = try await client.request(signedTransaction: verification.jwsRepresentation,
                                                    environment: transaction.environment == .sandbox ? "Sandbox" : "Production")
            guard snapshot.delivery?.transactionId == String(transaction.id) else { throw CloneCreditFailure.unverified }
            // Persisted server delivery is authoritative. Finish only after this acknowledgement.
            await transaction.finish()
            guard owner == account() else { return true }
            sequence &+= 1
            scope = owner
            apply(snapshot)
            environment = snapshot.environment ?? "Production"
            UserDefaults.standard.set(environment, forKey: "clone-credit-environment.\(owner)")
            pending.remove(transaction.id)
            hasPendingDelivery = !pending.isEmpty
            message = snapshot.delivery?.refunded == true ? AppLocalized("这笔购买已退款") : AppLocalized("120 分钟额度已到账")
            return true
        } catch {
            guard owner == account() else { return false }
            message = CloneCreditFailure.unavailable.localizedDescription
            scheduleRetry()
            return false
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let owner = account()
        retryTask = Task { [weak self] in
            for seconds in [5, 15, 30] {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, self.account() == owner else { return }
                for await verification in Transaction.unfinished { await self.deliver(verification) }
                if !self.hasPendingDelivery { break }
            }
            self?.retryTask = nil
        }
    }

    func applyGenerationResponse(_ response: HTTPURLResponse) {
        guard let raw = response.value(forHTTPHeaderField: "X-Clone-Credits"), let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CloneCreditBalance.self, from: data), account() != nil else { return }
        if scope != account() { resetScope() }
        sequence &+= 1
        apply(snapshot)
    }

    private func apply(_ snapshot: CloneCreditBalance) {
        if snapshot.environment == balance?.environment,
           let incoming = snapshot.revision, let current = balance?.revision, incoming < current { return }
        balance = snapshot
    }
}
