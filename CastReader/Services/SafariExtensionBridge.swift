//
//  SafariExtensionBridge.swift
//  CastReader
//
//  Shares only the minimum identity/entitlement snapshot needed by the Safari
//  WebExtension. StoreKit verification remains in the containing app.
//

import Foundation

@MainActor
enum SafariExtensionBridge {
    static let appGroup = "group.com.same.castreader"
    private static let snapshotKeyPrefix = "entitlementSnapshot.v2."

    static func syncFromApp() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let pro = ProManager.shared
        let auth = AuthService.shared
        let route = ServiceRouting.current.rawValue
        let snapshotKey = snapshotKeyPrefix + route

        // A route-only snapshot is not an account boundary: two users can log
        // into the same gateway. Signed-out/mid-switch state therefore removes
        // the route snapshot instead of preserving another user's identity or
        // server entitlement for the WebExtension.
        guard auth.isSignedIn,
              let accountStorageID = AccountContentScopeBridge.activeStorageID else {
            defaults.removeObject(forKey: snapshotKey)
            defaults.set(route, forKey: "serviceRoute")
            defaults.synchronize()
            return
        }
        var snapshot: [String: Any] = [
            "serviceRoute": route,
            "accountStorageID": accountStorageID,
            "isPro": pro.isPro,
            "storeKitLocalPro": pro.storeKitLocalPro,
            "serverPro": pro.serverPro,
            "deviceId": ProBackendService.deviceId,
            "updatedAt": Date().timeIntervalSince1970
        ]
        if let plan = pro.serverPlan, !plan.isEmpty {
            snapshot["plan"] = plan
        }
        if let email = auth.normalizedEmail, !email.isEmpty {
            snapshot["email"] = email
        }
        if let userId = auth.proUserId, !userId.isEmpty {
            snapshot["userId"] = userId
        }

        // Write one property-list dictionary atomically into the route's own
        // namespace. A CN identity must never overwrite the global snapshot
        // (or vice versa) while an older WebKit process is still alive.
        defaults.set(snapshot, forKey: snapshotKey)
        // The containing app is the only route authority. ServiceRouting.current
        // is already frozen for this app process; WebKit freezes the mirrored
        // value independently for each extension JavaScript process. Publish
        // this pointer last so readers can never observe a route before its
        // complete namespaced snapshot exists.
        defaults.set(route, forKey: "serviceRoute")
        defaults.synchronize()
    }

    /// Invalidates the selected route synchronously before AuthService
    /// publishes a different account. The next authoritative Pro refresh will
    /// write a snapshot bound to the new opaque account scope.
    static func invalidateForAccountBoundary() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let route = ServiceRouting.current.rawValue
        defaults.removeObject(forKey: snapshotKeyPrefix + route)
        defaults.set(route, forKey: "serviceRoute")
        defaults.synchronize()
    }
}
