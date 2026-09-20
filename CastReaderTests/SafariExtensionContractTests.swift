import XCTest
@testable import CastReader

final class SafariExtensionContractTests: XCTestCase {
    private let accountA = String(repeating: "a", count: 64)
    private let accountB = String(repeating: "b", count: 64)

    func testBackgroundSessionIdentityRequiresCanonicalPrincipalAndBoundary() {
        let snapshot: [String: Any] = ["userId": "canonical-a", "accountStorageID": accountA,
                                       "boundaryNonce": "login-a", "email": "qa@example.invalid",
                                       "identityToken": "private-provider-fixture"]
        let identity = SafariExtensionContract.sessionIdentity(snapshot)
        XCTAssertEqual(identity?["canonicalAccountId"] as? String, "canonical-a")
        XCTAssertNil(identity?["identityToken"])
        for key in ["userId", "accountStorageID", "boundaryNonce"] {
            var invalid = snapshot
            invalid.removeValue(forKey: key)
            XCTAssertNil(SafariExtensionContract.sessionIdentity(invalid))
        }
    }

    func testRefreshCannotReturnTheRejectedBearerAsRenewed() {
        let session = SafariSessionEnvelope(route: "global", accountStorageID: accountA,
                                             boundaryNonce: "login-1", sessionToken: "cms_current_fixture")
        XCTAssertEqual(session.tokenForRequest(refresh: false, rejectedToken: nil), "cms_current_fixture")
        XCTAssertNil(session.tokenForRequest(refresh: true, rejectedToken: "cms_current_fixture"))
        XCTAssertNil(session.tokenForRequest(refresh: true, rejectedToken: nil))
        XCTAssertNil(session.tokenForRequest(refresh: true, rejectedToken: "provider_fixture"))
        XCTAssertEqual(session.tokenForRequest(refresh: true, rejectedToken: "cms_old_fixture"), "cms_current_fixture")
    }

    func testSessionRequiresExactRouteAccountAndLoginBoundary() {
        let session = SafariSessionEnvelope(route: "cn", accountStorageID: accountA,
                                             boundaryNonce: "login-1", sessionToken: "cms_contract_fixture")
        XCTAssertTrue(session.matches(route: "cn", accountStorageID: accountA, boundaryNonce: "login-1"))
        XCTAssertFalse(session.matches(route: "global", accountStorageID: accountA, boundaryNonce: "login-1"))
        XCTAssertFalse(session.matches(route: "cn", accountStorageID: accountB, boundaryNonce: "login-1"))
        // A -> B -> A must not revive the first A session.
        XCTAssertFalse(session.matches(route: "cn", accountStorageID: accountA, boundaryNonce: "login-3"))
    }

    func testLocalAndMalformedCredentialsAreNeverShared() {
        for token in ["", "cms_", "cms_local_fixture", "provider_id_token", "cms_" + String(repeating: "x", count: 4096)] {
            let session = SafariSessionEnvelope(route: "global", accountStorageID: accountA,
                                                 boundaryNonce: "login-1", sessionToken: token)
            XCTAssertFalse(session.matches(route: "global", accountStorageID: accountA, boundaryNonce: "login-1"))
        }
    }

    func testEntitlementNeverExposesCredentialOrInternalScope() {
        let result = SafariExtensionContract.entitlement([
            "isPro": true, "storeKitLocalPro": false, "serverPro": true,
            "sessionToken": "cms_contract_fixture", "identityToken": "provider_fixture",
            "accountStorageID": accountA, "boundaryNonce": "login-1",
            "userId": "test-account", "email": "qa@example.invalid", "updatedAt": 123.0
        ], route: "cn")
        XCTAssertEqual(result["isPro"] as? Bool, true)
        XCTAssertEqual(result["serviceRoute"] as? String, "cn")
        XCTAssertEqual(result["userId"] as? String, "test-account")
        for key in ["sessionToken", "identityToken", "accountStorageID", "boundaryNonce"] {
            XCTAssertNil(result[key])
        }
    }

    func testSignedOutChinaSnapshotDoesNotFallBackToGlobal() {
        let result = SafariExtensionContract.entitlement([:], route: "cn")
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["serviceRoute"] as? String, "cn")
        XCTAssertEqual(result["isPro"] as? Bool, false)
        XCTAssertNil(result["userId"])
    }

    func testSnapshotMustMatchTheCurrentCrossProcessScope() {
        let snapshot: [String: Any] = [
            "serviceRoute": "global", "accountStorageID": accountA,
            "boundaryNonce": "login-1", "isPro": true
        ]
        XCTAssertTrue(SafariExtensionContract.matches(snapshot, route: "global", account: accountA, nonce: "login-1"))
        XCTAssertFalse(SafariExtensionContract.matches(snapshot, route: "cn", account: accountA, nonce: "login-1"))
        XCTAssertFalse(SafariExtensionContract.matches(snapshot, route: "global", account: accountB, nonce: "login-1"))
        XCTAssertFalse(SafariExtensionContract.matches(snapshot, route: "global", account: accountA, nonce: "login-3"))
        XCTAssertFalse(SafariExtensionContract.matches(snapshot, route: "global", account: accountA, nonce: ""))
    }

    func testAccountStoragePointerRequiresOpaqueSHA256() {
        XCTAssertEqual(SafariExtensionContract.validAccount(accountA), accountA)
        for value in ["", "debug-legacy", "email@example.invalid", String(repeating: "g", count: 64)] {
            XCTAssertNil(SafariExtensionContract.validAccount(value))
        }
        XCTAssertNil(SafariExtensionContract.validAccount(nil))
    }

    func testDedicatedKeychainRoundTripAndRegionalIsolation() {
        let priorGlobal = SafariSharedSessionStore.read(route: "global")
        let priorChina = SafariSharedSessionStore.read(route: "cn")
        defer {
            for (route, prior) in [("global", priorGlobal), ("cn", priorChina)] {
                SafariSharedSessionStore.remove(route: route)
                if let prior { XCTAssertTrue(SafariSharedSessionStore.write(prior)) }
            }
        }
        let global = SafariSessionEnvelope(route: "global", accountStorageID: accountA,
                                           boundaryNonce: "login-1", sessionToken: "cms_global_fixture")
        let china = SafariSessionEnvelope(route: "cn", accountStorageID: accountB,
                                          boundaryNonce: "login-2", sessionToken: "cms_china_fixture")
        XCTAssertTrue(SafariSharedSessionStore.write(global))
        XCTAssertTrue(SafariSharedSessionStore.write(china))
        XCTAssertEqual(SafariSharedSessionStore.read(route: "global"), global)
        XCTAssertEqual(SafariSharedSessionStore.read(route: "cn"), china)
        let invalid = SafariSessionEnvelope(route: "global", accountStorageID: accountA,
                                            boundaryNonce: "login-1", sessionToken: "provider_fixture")
        XCTAssertFalse(SafariSharedSessionStore.write(invalid))
        XCTAssertEqual(SafariSharedSessionStore.read(route: "global"), global)
        SafariSharedSessionStore.remove(route: "global")
        XCTAssertNil(SafariSharedSessionStore.read(route: "global"))
        XCTAssertEqual(SafariSharedSessionStore.read(route: "cn"), china)
    }

    func testHandoffIsSingleUseAndDoesNotEncodeAccountData() throws {
        let name = "SafariHandoffTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("global", forKey: "serviceRoute")
        defaults.set(accountA, forKey: SafariExtensionContract.accountKey)
        defaults.set("boundary-a", forKey: SafariExtensionContract.nonceKey)
        let now = Date(timeIntervalSince1970: 1_000)
        let url = try XCTUnwrap(SafariAppHandoff.issue(.signOut, route: "global", defaults: defaults, now: now))
        XCTAssertFalse(url.absoluteString.contains(accountA))
        XCTAssertFalse(url.absoluteString.contains("signOut"))
        XCTAssertEqual(SafariAppHandoff.consume(url, route: "global", defaults: defaults, now: now), .signOut)
        XCTAssertNil(SafariAppHandoff.consume(url, route: "global", defaults: defaults, now: now))
        XCTAssertNil(SafariAppHandoff.consume(URL(string: "castreader://account?action=signout")!, route: "global", defaults: defaults, now: now))
    }

    func testHandoffRejectsExpiredChangedAccountAndChangedRoute() throws {
        let name = "SafariHandoffTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_000)
        for change in ["expired", "future", "account", "boundary", "route"] {
            defaults.set("global", forKey: "serviceRoute")
            defaults.set(accountA, forKey: SafariExtensionContract.accountKey)
            defaults.set("boundary-a", forKey: SafariExtensionContract.nonceKey)
            let url = try XCTUnwrap(SafariAppHandoff.issue(.pro, route: "global", defaults: defaults, now: now))
            if change == "account" { defaults.set(accountB, forKey: SafariExtensionContract.accountKey) }
            if change == "boundary" { defaults.set("boundary-a-new", forKey: SafariExtensionContract.nonceKey) }
            if change == "route" { defaults.set("cn", forKey: "serviceRoute") }
            let time = now.addingTimeInterval(change == "expired" ? 121 : change == "future" ? -1 : 1)
            XCTAssertNil(SafariAppHandoff.consume(url, route: "global", defaults: defaults, now: time), change)
        }
    }

    func testSignedOutHandoffCanOpenLoginButCannotSignOut() throws {
        let name = "SafariHandoffTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("global", forKey: "serviceRoute")
        XCTAssertNil(SafariAppHandoff.issue(.signOut, route: "global", defaults: defaults))
        let url = try XCTUnwrap(SafariAppHandoff.issue(.account, route: "global", defaults: defaults))
        XCTAssertEqual(SafariAppHandoff.consume(url, route: "global", defaults: defaults), .account)
        XCTAssertNil(SafariAppHandoff.issue(.account, route: "cn", defaults: defaults))
    }
}
