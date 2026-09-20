import XCTest
@testable import CastReader

final class SafariExtensionContractTests: XCTestCase {
    private let accountA = String(repeating: "a", count: 64)
    private let accountB = String(repeating: "b", count: 64)

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
}
