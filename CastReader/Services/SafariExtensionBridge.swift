import Foundation
import Combine

@MainActor
final class SafariAppRouteCenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let action: SafariHandoffAction
    }
    static let shared = SafariAppRouteCenter()
    @Published var request: Request?

    func open(_ url: URL) {
        guard !AuthService.shared.isWorking,
              let defaults = UserDefaults(suiteName: SafariExtensionContract.appGroup),
              let action = SafariAppHandoff.consume(url, route: ServiceRouting.current.rawValue,
                                                   defaults: defaults) else { return }
        request = Request(action: action)
    }
}

@MainActor
enum SafariExtensionBridge {
    static func syncFromApp() {
        guard let defaults = UserDefaults(suiteName: SafariExtensionContract.appGroup) else { return }
        let route = ServiceRouting.current.rawValue
        let auth = AuthService.shared
        guard !auth.isWorking, auth.isSignedIn,
              let account = AccountContentScopeBridge.activeStorageID,
              let nonce = defaults.string(forKey: SafariExtensionContract.nonceKey),
              let token = MobileSessionStore.persistedSessionToken(for: ServiceRouting.current),
              MobileSessionStore.isServerSessionToken(token) else {
            invalidateForAccountBoundary()
            return
        }
        let envelope = SafariSessionEnvelope(route: route, accountStorageID: account,
                                             boundaryNonce: nonce, sessionToken: token)
        guard SafariSharedSessionStore.write(envelope) else {
            invalidateForAccountBoundary()
            return
        }
        let pro = ProManager.shared
        var snapshot: [String: Any] = [
            "serviceRoute": route, "accountStorageID": account, "boundaryNonce": nonce,
            "isPro": pro.isPro, "storeKitLocalPro": pro.storeKitLocalPro,
            "serverPro": pro.serverPro, "deviceId": ProBackendService.deviceId,
            "updatedAt": Date().timeIntervalSince1970
        ]
        snapshot["plan"] = pro.serverPlan
        snapshot["email"] = auth.normalizedEmail
        snapshot["userId"] = auth.proUserId
        defaults.set(snapshot, forKey: SafariExtensionContract.snapshotPrefix + route)
        defaults.set(route, forKey: "serviceRoute")
        defaults.synchronize()
    }

    static func scheduleSyncFromApp() {
        // Published account/isWorking changes settle on the main actor before
        // projecting a session. A login in progress must not pair a new bearer
        // with the previous account's entitlement snapshot.
        Task { @MainActor in syncFromApp() }
    }

    static func invalidateForAccountBoundary() {
        let route = ServiceRouting.current.rawValue
        let defaults = UserDefaults(suiteName: SafariExtensionContract.appGroup)
        defaults?.removeObject(forKey: SafariExtensionContract.snapshotPrefix + route)
        defaults?.set(route, forKey: "serviceRoute")
        defaults?.synchronize()
        SafariSharedSessionStore.remove(route: route)
    }
}
