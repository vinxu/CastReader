import XCTest
import StoreKit
import StoreKitTest
import AVFoundation
import SwiftUI
@testable import CastReader

/// Uses real simulator StoreKit transactions and the loopback HTTP server's
/// PostgreSQL ledger. The test server pins Xcode's signing certificate.
@MainActor
final class CloneCreditPurchaseTests: XCTestCase {
    private var session: SKTestSession!
    private var owner = ""
    private var token = ""
    private let base = URL(string: "http://127.0.0.1:55446")!
    private var store: CloneCreditStore!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["CASTREADER_CLONE_CREDIT_LOOPBACK_TESTS"] == "1" else {
            throw XCTSkip("Requires the explicit disposable PostgreSQL / loopback StoreKit harness; online Sandbox is tested on the physical device separately")
        }
        session = try SKTestSession(configurationFileNamed: "Configuration")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        owner = "clone-simulator-" + UUID().uuidString.lowercased()
        try await control("reset-ledger")
        let seeded = try await control("seed")
        token = try XCTUnwrap(seeded["token"] as? String)
        store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.currentBalance?.availableMs, 7_200_000, store.message ?? "No balance")
        XCTAssertNotNil(store.product)
    }

    override func tearDown() async throws {
        _ = try? await control("fault")
        session?.clearTransactions()
        store = nil
    }

    private func makeStore(owner: String? = nil, token: String? = nil) -> CloneCreditStore {
        let id = owner ?? self.owner, bearer = token ?? self.token
        return CloneCreditStore(client: CloneCreditClient(baseURL: base,
            token: { bearer }, refreshToken: { nil }), account: { id }, hasPro: { true }, storeEnvironment: { nil })
    }

    @discardableResult
    private func control(_ action: String, fields: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent("control"))
        request.httpMethod = "POST"
        request.setValue("local-clone-credit-acceptance-only", forHTTPHeaderField: "X-Test-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields.merging(["owner": owner, "action": action]) { _, new in new })
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func speech(requestID: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: base.appendingPathComponent("api/voice-clone/captioned-speech"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        request.setValue("Sandbox", forHTTPHeaderField: "X-Clone-Billing-Environment")
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": "Hello", "voice": "vc_credit_test_voice", "language": "en", "speed": 1])
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    func testPurchaseAtPositiveBalanceRepeatPurchaseAndServerReplay() async throws {
        if ProcessInfo.processInfo.environment["CASTREADER_CREDIT_UI_ACCEPTANCE"] == "1" {
            session.disableDialogs = false
            let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow })
            let controller = UIHostingController(rootView: CloneCreditPurchaseView(store: store)
                .environmentObject(ReaderSceneContext.legacy))
            controller.modalPresentationStyle = .fullScreen
            window.rootViewController?.present(controller, animated: false)
            defer { controller.dismiss(animated: false) }
            for _ in 0..<1800 {
                if store.currentBalance?.purchasedRemainingMs == 14_400_000 { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 14_400_000)
            XCTAssertEqual(store.availableMs, 21_600_000)
            try await Task.sleep(for: .seconds(10)) // retain the result for visual acceptance
            return
        }
        await store.purchase()
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 7_200_000, store.message ?? "No delivery")
        XCTAssertEqual(store.currentBalance?.availableMs, 14_400_000)
        XCTAssertFalse(store.hasPendingDelivery)
        await store.purchase()
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 14_400_000)
        await store.recover()
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 14_400_000)
        for await verification in StoreKit.Transaction.unfinished {
            if case .verified(let transaction) = verification { XCTAssertNotEqual(transaction.productID, CloneCreditStore.productID) }
        }
    }

    func testZeroBalancePurchaseGenerateReplayAndFailureRelease() async throws {
        try await control("base-zero")
        await store.refresh()
        XCTAssertEqual(store.currentBalance?.availableMs, 0)
        XCTAssertEqual(store.currentBalance?.canPurchase, true)
        await store.purchase()
        XCTAssertEqual(store.currentBalance?.availableMs, 7_200_000)
        let id = UUID().uuidString
        let (data, response) = try await speech(requestID: id)
        XCTAssertEqual(response.statusCode, 200, String(data: data, encoding: .utf8) ?? "")
        store.applyGenerationResponse(response)
        let after = try XCTUnwrap(store.availableMs)
        XCTAssertLessThan(after, 7_200_000)
        XCTAssertGreaterThan(after, 7_198_000)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let audio = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(json["audio"] as? String)))
        let player = try AVAudioPlayer(data: audio)
        XCTAssertGreaterThan(player.duration, 0.9)
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertTrue(player.play())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(player.isPlaying)
        player.stop()
        let (_, replayResponse) = try await speech(requestID: id)
        XCTAssertEqual(replayResponse.statusCode, 200)
        await store.refresh()
        XCTAssertEqual(store.availableMs, after)
        try await control("fault", fields: ["generation": true])
        let (_, failed) = try await speech(requestID: UUID().uuidString)
        XCTAssertEqual(failed.statusCode, 503)
        await store.refresh()
        XCTAssertEqual(store.availableMs, after)
    }

    func testLostAcknowledgementRecoversOnFreshStoreWithoutDoubleCredit() async throws {
        try await control("fault", fields: ["dropResponse": true])
        await store.purchase()
        XCTAssertTrue(store.hasPendingDelivery)
        var unfinished: VerificationResult<StoreKit.Transaction>?
        for await verification in StoreKit.Transaction.unfinished { unfinished = verification }
        XCTAssertNotNil(unfinished, "Transaction must remain unfinished until durable server acknowledgement")
        try await control("fault")
        let restarted = makeStore()
        await restarted.recover()
        XCTAssertEqual(restarted.currentBalance?.purchasedRemainingMs, 7_200_000, restarted.message ?? "Missing recovery")
        if let unfinished {
            _ = await restarted.deliver(unfinished)
            XCTAssertEqual(restarted.currentBalance?.purchasedRemainingMs, 7_200_000)
        }
    }

    func testPaymentOutageRecoveryAndProExpiryRetainsPaidBalance() async throws {
        try await control("fault", fields: ["delivery": true])
        await store.purchase()
        XCTAssertTrue(store.hasPendingDelivery)
        try await control("fault")
        try await control("pro", fields: ["enabled": false])
        await store.recover()
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 7_200_000)
        XCTAssertEqual(store.currentBalance?.canPurchase, false)
        XCTAssertEqual(store.currentBalance?.canApply, false)
        XCTAssertFalse(store.hasPendingDelivery)
        try await control("pro", fields: ["enabled": true])
        await store.refresh()
        XCTAssertEqual(store.currentBalance?.canApply, true)
    }
    func testPurchasedBalancePaysForLiveGeneratedAudioAndReplayIsFree() async throws {
        try await control("base-zero")
        await store.purchase()
        XCTAssertEqual(store.availableMs, 7_200_000)
        let id = "real-worker-" + UUID().uuidString
        let (data, response) = try await speech(requestID: id)
        XCTAssertEqual(response.statusCode, 200, String(data: data, encoding: .utf8) ?? "")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result["audio"] as? String)))
        let player = try AVAudioPlayer(data: bytes)
        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertTrue(player.play())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(player.isPlaying)
        player.stop()
        store.applyGenerationResponse(response)
        let charged = 7_200_000 - (try XCTUnwrap(store.availableMs))
        XCTAssertEqual(Double(charged), ceil(player.duration * 1000), accuracy: 50)
        let calls = try await control("inspect")["workerCalls"] as? Int
        let (replay, replayResponse) = try await speech(requestID: id)
        XCTAssertEqual(replayResponse.statusCode, 200)
        let replayJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: replay) as? [String: Any])
        XCTAssertEqual(replayJSON["audio"] as? String, result["audio"] as? String)
        let afterCalls = try await control("inspect")["workerCalls"] as? Int
        XCTAssertEqual(afterCalls, calls)
        await store.refresh()
        XCTAssertEqual(store.availableMs, 7_200_000 - charged)
    }

    func testCancellationDoesNotChargeOrBlockAnotherPurchase() async throws {
        try await session.setSimulatedError(.generic(StoreKitError.userCancelled), forAPI: .purchase)
        await store.purchase()
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 0)
        XCTAssertFalse(store.isPurchasing)
        XCTAssertFalse(store.hasPendingDelivery)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        let remainingError = await session.simulatedError(forAPI: .purchase)
        XCTAssertNil(remainingError)
        // iOS 26.2 retains the injected purchase batch failure after clearing
        // simulatedError. Reset the test daemon's overrides; keep the same app
        // store and server ledger. Real sheet cancellation is covered by UI acceptance.
        session.resetToDefaultState()
        session.disableDialogs = true
        await store.purchase()
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 7_200_000, store.message ?? "No delivery after cancellation")
    }

    func testExhaustedRequestWaitsForPurchaseAndResumesOnlyAfterDelivery() async throws {
        try await control("base-zero")
        await store.refresh()
        let access = VoiceCloneAccessCoordinator()
        let waiting = Task { try await access.waitForCreditPurchase() }
        await Task.yield()
        XCTAssertTrue(access.hasCreditWaiters)
        access.continueAfterCreditPurchase(store: store)
        XCTAssertTrue(access.hasCreditWaiters, "Zero balance must not resume generation")
        await store.purchase()
        access.continueAfterCreditPurchase(store: store)
        let resumed = try await waiting.value
        XCTAssertTrue(resumed)
        XCTAssertFalse(access.hasCreditWaiters)
        let (_, response) = try await speech(requestID: UUID().uuidString)
        XCTAssertEqual(response.statusCode, 200)
    }

    func testDismissedAndCancelledCreditWaitsReleaseTheRequest() async throws {
        let access = VoiceCloneAccessCoordinator()
        let dismissed = Task { try await access.waitForCreditPurchase() }
        await Task.yield()
        access.prompt = nil
        let resumed = try await dismissed.value
        XCTAssertFalse(resumed)
        let cancelled = Task { try await access.waitForCreditPurchase() }
        await Task.yield()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled playback must not resume generation")
        } catch is CancellationError { }
        XCTAssertFalse(access.hasCreditWaiters)
    }

    func testAskToBuyDoesNotCreditBeforeApprovalAndUpdatesDeliverAfterApproval() async throws {
        store.start()
        session.askToBuyEnabled = true
        await store.purchase()
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 0)
        let deferred = try XCTUnwrap(session.allTransactions().first { $0.state == .deferred })
        try session.approveAskToBuyTransaction(identifier: deferred.identifier)
        for _ in 0..<50 {
            if store.currentBalance?.purchasedRemainingMs == 7_200_000 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 7_200_000, store.message ?? "Approval not delivered")
    }

    func testAnotherAccountCannotClaimPendingTransaction() async throws {
        try await control("fault", fields: ["delivery": true])
        await store.purchase()
        var pending: VerificationResult<StoreKit.Transaction>?
        for await verification in StoreKit.Transaction.unfinished { pending = verification }
        let transaction = try XCTUnwrap(pending)
        let original = owner
        owner = "clone-simulator-" + UUID().uuidString.lowercased()
        let other = try await control("seed")
        let otherStore = makeStore(owner: owner, token: try XCTUnwrap(other["token"] as? String))
        let claimed = await otherStore.deliver(transaction)
        XCTAssertFalse(claimed)
        await otherStore.refresh()
        XCTAssertEqual(otherStore.currentBalance?.purchasedRemainingMs, 0)
        owner = original
        await store.recover()
        XCTAssertEqual(store.currentBalance?.purchasedRemainingMs, 7_200_000)
    }

}


final class CloneCreditEnvironmentTests: XCTestCase {
    func testProductionRuntimeRejectsRecoveredSandboxBalance() {
        XCTAssertFalse(CloneCreditStore.acceptsBalanceEnvironment("Sandbox", current: "Production"))
        XCTAssertTrue(CloneCreditStore.acceptsBalanceEnvironment("Production", current: "Production"))
    }
    func testSandboxRuntimeCannotBeOverwrittenByLateProductionResponse() {
        XCTAssertFalse(CloneCreditStore.acceptsBalanceEnvironment("Production", current: "Sandbox"))
        XCTAssertTrue(CloneCreditStore.acceptsBalanceEnvironment("Sandbox", current: "Sandbox"))
    }
    func testDevelopmentRuntimeMayLearnEnvironmentFromVerifiedPurchase() {
        XCTAssertTrue(CloneCreditStore.acceptsBalanceEnvironment("Sandbox", current: nil))
    }
}
