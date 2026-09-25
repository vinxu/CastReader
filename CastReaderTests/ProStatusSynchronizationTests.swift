import XCTest
@testable import CastReader

@MainActor
final class ProStatusSynchronizationTests: XCTestCase {
    // Real HTTP 200 response captured 2026-09-25 from the reported past_due
    // account. Account identity/profile/assignment are removed; no credential.
    private let revokedResponse = #"""
{
  "code": 0,
  "data": {
    "pro": false,
    "plan": null,
    "account": null,
    "freeRemaining": 0,
    "freeMax": 0,
    "listenSeconds": 0,
    "listenLimit": 300,
    "listenRemaining": 300,
    "quotaPolicy": "two_tier_v1",
    "grantListenMax": 300,
    "grantListenRemaining": 300,
    "grantExplainMax": 0,
    "grantExplainRemaining": 0,
    "monthlyListenMax": 0,
    "monthlyListenRemaining": 0,
    "monthlyExplainMax": 0,
    "monthlyExplainRemaining": 0,
    "growthConfig": null,
    "contract": "mobile-pro-v2",
    "proIdentity": "authenticated_user_id",
    "quotaIdentity": "authenticated_user_route",
    "resolvedUserId": "support-replay-account",
    "clonePolicy": "monthly_120_v1",
    "cloneCanCreate": true,
    "cloneCanApply": false,
    "cloneFreeCreationConsumed": false,
    "cloneMonthlyLimitSeconds": 7200,
    "cloneMonthlyUsedSeconds": 0,
    "cloneMonthlyRemainingSeconds": 7200,
    "cloneQuotaResetAt": "2026-10-01T00:00:00.000Z"
  }
}
"""#

    private func revokedStatus() throws -> ProStatusDTO {
        try ProStatusDTO.decodeServerResponse(from: Data(revokedResponse.utf8))
    }

    func testExistingServerProConvergesWithFreshDeviceOnActualRevokedResponse() throws {
        let existing = ProManager.makeForTesting()
        let fresh = ProManager.makeForTesting()
        existing.setEntitlementsForTesting(storeKit: false, server: true)
        XCTAssertTrue(existing.isPro)
        XCTAssertFalse(fresh.isPro)
        let status = try revokedStatus()
        existing.applyServerEntitlement(status, userId: status.resolvedUserId, email: nil, read: existing.beginServerRead())
        fresh.applyServerEntitlement(status, userId: status.resolvedUserId, email: nil, read: fresh.beginServerRead())
        XCTAssertFalse(existing.isPro)
        XCTAssertEqual(existing.isPro, fresh.isPro)
    }

    func testAuthoritativeFalseOverridesOldLocalStoreKitSnapshot() throws {
        let existing = ProManager.makeForTesting()
        existing.setEntitlementsForTesting(storeKit: true, server: true)
        let status = try revokedStatus()
        existing.applyServerEntitlement(status, userId: status.resolvedUserId, email: nil, read: existing.beginServerRead())
        XCTAssertFalse(existing.serverPro)
        XCTAssertFalse(existing.isPro, "A successful server false must override the old local crown")
    }

    func testLocalPurchaseAloneCannotResurrectProBeforeServerConfirmation() {
        let manager = ProManager.makeForTesting()
        manager.setLocalStoreKitForTesting(true)
        XCTAssertFalse(manager.isPro)
    }

    func testAccountBoundaryClearsBothSources() {
        let manager = ProManager.makeForTesting()
        manager.setEntitlementsForTesting(storeKit: true, server: true)
        manager.clearEntitlementsForAccountTransition()
        XCTAssertFalse(manager.isPro)
    }

    private func activeStatus() throws -> ProStatusDTO {
        try ProStatusDTO.decodeServerResponse(from: Data(
            #"{"data":{"pro":true,"plan":"monthly","resolvedUserId":"support-replay-account"}}"#.utf8
        ))
    }

    private func apply(_ status: ProStatusDTO?, to manager: ProManager) {
        manager.applyServerEntitlement(status, userId: "support-replay-account",
                                       email: nil, read: manager.beginServerRead())
    }

    func testUnavailableNeverBecomesFalseOrResurrectsTrue() throws {
        let manager = ProManager.makeForTesting()
        apply(try activeStatus(), to: manager)
        for _ in 0..<100 { apply(nil, to: manager) }
        XCTAssertTrue(manager.isPro, "Weak network must retain the last successful true")
        apply(try revokedStatus(), to: manager)
        manager.setLocalStoreKitForTesting(true)
        for _ in 0..<100 { apply(nil, to: manager) }
        XCTAssertFalse(manager.isPro, "Weak network must retain the last successful false")
    }

    func testSuccessfulSubscriptionOnAnotherChannelRestoresPro() throws {
        let manager = ProManager.makeForTesting()
        apply(try revokedStatus(), to: manager)
        XCTAssertFalse(manager.isPro)
        // Server aggregates all providers. A later successful Apple/Play
        // subscription returns true even while a Stripe row remains past_due.
        apply(try activeStatus(), to: manager)
        manager.setLocalStoreKitForTesting(false)
        XCTAssertTrue(manager.isPro)
    }

    func testDelayedOldTrueCannotOverwriteNewFalse() throws {
        let manager = ProManager.makeForTesting()
        let old = manager.beginServerRead()
        apply(try revokedStatus(), to: manager)
        XCTAssertFalse(manager.applyServerEntitlement(try activeStatus(),
            userId: "support-replay-account", email: nil, read: old))
        XCTAssertFalse(manager.isPro)
    }

    func testDelayedOldFalseCannotOverwriteNewTrue() throws {
        let manager = ProManager.makeForTesting()
        let old = manager.beginServerRead()
        apply(try activeStatus(), to: manager)
        XCTAssertFalse(manager.applyServerEntitlement(try revokedStatus(),
            userId: "support-replay-account", email: nil, read: old))
        XCTAssertTrue(manager.isPro)
    }

    func testClearingAccountInvalidatesInFlightStatus() throws {
        let manager = ProManager.makeForTesting()
        let old = manager.beginServerRead()
        manager.clearEntitlementsForAccountTransition()
        XCTAssertFalse(manager.applyServerEntitlement(try activeStatus(),
            userId: "support-replay-account", email: nil, read: old))
        XCTAssertFalse(manager.isPro)
    }

    func testStatusForAnotherPrincipalCannotGrantPro() throws {
        let manager = ProManager.makeForTesting()
        XCTAssertFalse(manager.applyServerEntitlement(try activeStatus(),
            userId: "different-account", email: nil, read: manager.beginServerRead()))
        XCTAssertFalse(manager.isPro)
    }

    func testSignOutClearsBothSourcesSynchronously() {
        let manager = ProManager.shared
        manager.debugForcePro = false
        manager.setEntitlementsForTesting(storeKit: true, server: true)
        AuthService.shared.signOut()
        XCTAssertFalse(manager.serverPro)
        XCTAssertFalse(manager.storeKitLocalPro)
        XCTAssertFalse(manager.isPro)
    }

    func testSameAccountProfileUpdateKeepsAuthoritativeFalse() throws {
        let account = UserAccount(id: "replay-provider", email: "replay@example.invalid",
            name: "Replay", pictureURL: nil, provider: "google",
            backendUserId: "support-replay-account")
        AuthService.shared.applyAccount(account)
        defer { AuthService.shared.signOut() }
        let manager = ProManager.shared
        manager.debugForcePro = false
        manager.setEntitlementsForTesting(storeKit: true, server: true)
        apply(try revokedStatus(), to: manager)
        var updated = account
        updated.name = "Updated profile"
        AuthService.shared.applyAccount(updated)
        XCTAssertFalse(manager.isPro)
        XCTAssertFalse(manager.serverPro)
    }

    func testChangedAccountBoundaryRejectsOutstandingRequest() throws {
        let manager = ProManager.makeForTesting()
        let old = manager.beginServerRead()
        AuthService.shared.applyAccount(UserAccount(id: "next-provider",
            email: "next@example.invalid", name: "Next", pictureURL: nil,
            provider: "google", backendUserId: "next-account"))
        defer { AuthService.shared.signOut() }
        XCTAssertFalse(manager.applyServerEntitlement(try activeStatus(),
            userId: "support-replay-account", email: nil, read: old))
        XCTAssertFalse(manager.isPro)
    }
}
