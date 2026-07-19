import Foundation
import os.log
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let appGroup = "group.com.same.castreader"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let type = message["type"] as? String ?? ""

        switch type {
        case "GET_ENTITLEMENT":
            complete(context, response: entitlementSnapshot())
        case "OPEN_PRO":
            guard let url = URL(string: "castreader://pro?source=safari_extension") else {
                complete(context, response: ["ok": false, "error": "invalid_url"])
                return
            }
            open(url, destination: "ios_storekit", context: context)
        case "OPEN_ACCOUNT":
            let mode = message["mode"] as? String ?? "login"
            var components = URLComponents()
            components.scheme = "castreader"
            components.host = "account"
            components.queryItems = [
                URLQueryItem(name: "source", value: "safari_extension"),
                URLQueryItem(name: "mode", value: mode)
            ]
            guard let url = components.url else {
                complete(context, response: ["ok": false, "error": "invalid_url"])
                return
            }
            open(url, destination: "ios_account", context: context)
        case "SIGN_OUT":
            guard let url = URL(string: "castreader://account?source=safari_extension&action=signout") else {
                complete(context, response: ["ok": false, "error": "invalid_url"])
                return
            }
            open(url, destination: "ios_signout", context: context)
        default:
            complete(context, response: ["ok": false, "error": "unsupported_message"])
        }
    }

    private func open(_ url: URL, destination: String, context: NSExtensionContext) {
        context.open(url) { [weak self] opened in
            self?.complete(
                context,
                response: ["ok": opened, "destination": destination]
            )
        }
    }

    private func entitlementSnapshot() -> [String: Any] {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            return ["ok": false, "error": "app_group_unavailable"]
        }
        var response: [String: Any] = [
            "ok": true,
            "isPro": defaults.bool(forKey: "isPro"),
            "storeKitLocalPro": defaults.bool(forKey: "storeKitLocalPro"),
            "serverPro": defaults.bool(forKey: "serverPro"),
            "updatedAt": defaults.double(forKey: "updatedAt")
        ]
        for key in ["plan", "deviceId", "email", "userId"] {
            if let value = defaults.string(forKey: key), !value.isEmpty {
                response[key] = value
            }
        }
        return response
    }

    private func complete(_ context: NSExtensionContext, response: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item])
    }
}
