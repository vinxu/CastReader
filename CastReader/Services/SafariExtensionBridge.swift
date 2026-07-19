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

    static func syncFromApp() {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let pro = ProManager.shared
        let auth = AuthService.shared
        defaults.set(pro.isPro, forKey: "isPro")
        defaults.set(pro.storeKitLocalPro, forKey: "storeKitLocalPro")
        defaults.set(pro.serverPro, forKey: "serverPro")
        defaults.set(pro.serverPlan, forKey: "plan")
        defaults.set(ProBackendService.deviceId, forKey: "deviceId")
        defaults.set(auth.normalizedEmail, forKey: "email")
        defaults.set(auth.proUserId, forKey: "userId")
        defaults.set(Date().timeIntervalSince1970, forKey: "updatedAt")
    }
}
