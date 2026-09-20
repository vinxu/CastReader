import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let type = message["type"] as? String ?? ""
        guard let defaults = UserDefaults(suiteName: SafariExtensionContract.appGroup) else {
            complete(context, ["ok": false, "error": "app_group_unavailable"])
            return
        }
        let route = SafariExtensionContract.route(defaults.string(forKey: "serviceRoute"))
        let expected = message["expectedServiceRoute"] as? String
        if type != "GET_ENTITLEMENT" && expected == nil {
            complete(context, ["ok": false, "serviceRoute": route, "error": "expected_service_route_required"])
            return
        }
        if let expected, expected != route {
            complete(context, ["ok": false, "serviceRoute": route, "error": "service_route_changed_restart_required"])
            return
        }
        let account = SafariExtensionContract.validAccount(defaults.string(forKey: SafariExtensionContract.accountKey))
        let nonce = defaults.string(forKey: SafariExtensionContract.nonceKey) ?? ""
        let snapshot = defaults.dictionary(forKey: SafariExtensionContract.snapshotPrefix + route) ?? [:]
        let isCurrent = account.map {
            SafariExtensionContract.matches(snapshot, route: route, account: $0, nonce: nonce)
        } ?? false

        switch type {
        case "GET_ENTITLEMENT":
            // Even a signed-out CN app remains CN. Never freeze the extension
            // to global just because an account snapshot is absent.
            complete(context, SafariExtensionContract.entitlement(isCurrent ? snapshot : [:], route: route))
        case "GET_MOBILE_SESSION", "REFRESH_MOBILE_SESSION":
            guard isCurrent, let account,
                  let session = SafariSharedSessionStore.read(route: route),
                  session.matches(route: route, accountStorageID: account, boundaryNonce: nonce) else {
                complete(context, ["ok": false, "serviceRoute": route, "error": "mobile_session_unavailable"])
                return
            }
            // Refresh can pick up a bearer already renewed by the App. OAuth
            // refresh credentials never leave the App's private access group.
            guard let token = session.tokenForRequest(refresh: type == "REFRESH_MOBILE_SESSION",
                                                       rejectedToken: message["rejectedToken"] as? String) else {
                complete(context, ["ok": false, "serviceRoute": route, "error": "mobile_session_refresh_required"])
                return
            }
            complete(context, ["ok": true, "serviceRoute": route, "sessionToken": token])
        case "OPEN_PRO", "OPEN_ACCOUNT", "SIGN_OUT":
            let action: SafariHandoffAction = type == "SIGN_OUT" ? .signOut
                : (type == "OPEN_PRO" || message["mode"] as? String == "manage_pro" ? .pro : .account)
            guard let url = SafariAppHandoff.issue(action, route: route, defaults: defaults) else {
                complete(context, ["ok": false, "error": "app_handoff_unavailable"])
                return
            }
            context.open(url) { opened in
                self.complete(context, ["ok": opened, "destination": action == .pro ? "ios_storekit" : "ios_account"])
            }
        default:
            complete(context, ["ok": false, "error": "unsupported_message"])
        }
    }

    private func complete(_ context: NSExtensionContext, _ response: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item])
    }
}
