import Foundation
import os.log
import SafariServices
import Security

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let appGroup = "group.com.same.castreader"
    private let snapshotKeyPrefix = "entitlementSnapshot.v2."
    private let activeAccountStorageIDKey = "account.content.activeStorageID.v1"
    private let keychainService = "ai.castreader.auth"
    private let globalSessionAccount = "castreader_mobile_session_v1"
    private let chinaSessionAccount = "castreader_mobile_session_v1.cn"
    private let sessionProviderAccount = "castreader_mobile_session_provider_v1"
    private let sessionIdentityTokenAccount = "castreader_mobile_identity_token_v1"
    private let keychainAccessGroupInfoKey = "CastReaderSharedKeychainAccessGroup"

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let type = message["type"] as? String ?? ""

        switch type {
        case "GET_ENTITLEMENT":
            complete(
                context,
                response: entitlementSnapshot(
                    expectedRoute: message["expectedServiceRoute"] as? String
                )
            )
        case "GET_MOBILE_SESSION":
            complete(
                context,
                response: mobileSessionSnapshot(
                    expectedRoute: message["expectedServiceRoute"] as? String
                )
            )
        case "REFRESH_MOBILE_SESSION":
            refreshMobileSession(
                context,
                expectedRoute: message["expectedServiceRoute"] as? String
            )
        case "OPEN_PRO":
            if let rejection = routeBoundActionRejection(message: message) {
                complete(context, response: rejection)
                return
            }
            guard let url = URL(string: "castreader://pro?source=safari_extension") else {
                complete(context, response: ["ok": false, "error": "invalid_url"])
                return
            }
            open(url, destination: "ios_storekit", context: context)
        case "OPEN_ACCOUNT":
            if let rejection = routeBoundActionRejection(message: message) {
                complete(context, response: rejection)
                return
            }
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
            if let rejection = routeBoundActionRejection(message: message) {
                complete(context, response: rejection)
                return
            }
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

    /// Mutating/navigation actions are bound to the immutable route selected by
    /// the calling JS process. A stale WebKit process must not open the app and
    /// accidentally act on the opposite route's account or StoreKit context.
    private func routeBoundActionRejection(message: [String: Any]) -> [String: Any]? {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            return [
                "ok": false,
                "error": "app_group_unavailable",
                "serviceRoute": "global"
            ]
        }
        let activeRoute = normalizedPersistedRoute(defaults.string(forKey: "serviceRoute"))
        guard let expectedRoute = message["expectedServiceRoute"] as? String,
              isCurrentRouteValue(expectedRoute) else {
            return [
                "ok": false,
                "error": "expected_service_route_required",
                "serviceRoute": activeRoute
            ]
        }
        guard expectedRoute == activeRoute else {
            return [
                "ok": false,
                "error": "service_route_changed_restart_required",
                "serviceRoute": activeRoute
            ]
        }
        return nil
    }

    private func entitlementSnapshot(expectedRoute: String?) -> [String: Any] {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            return [
                "ok": false,
                "error": "app_group_unavailable",
                "serviceRoute": "global"
            ]
        }

        // Missing/corrupt App Group data fails to the new app's global gateway.
        // The local-only `legacy` alias migrates an earlier TestFlight snapshot;
        // it is never emitted to JavaScript or accepted by a server endpoint.
        let activeRoute = normalizedPersistedRoute(defaults.string(forKey: "serviceRoute"))
        if let expectedRoute,
           isCurrentRouteValue(expectedRoute),
           expectedRoute != activeRoute {
            // Do not disclose the opposite route's identity. The JS process
            // must stop owned requests until WebKit starts a fresh process.
            return [
                "ok": false,
                "error": "service_route_changed_restart_required",
                "serviceRoute": activeRoute
            ]
        }

        let snapshotKey = snapshotKeyPrefix + activeRoute
        guard let activeAccountStorageID = activeAccountStorageID(in: defaults) else {
            return [
                "ok": false,
                "error": "account_scope_unavailable",
                "serviceRoute": activeRoute
            ]
        }
        guard let snapshot = defaults.dictionary(forKey: snapshotKey),
              snapshot["serviceRoute"] as? String == activeRoute,
              snapshot["accountStorageID"] as? String == activeAccountStorageID else {
            return [
                "ok": false,
                "error": "entitlement_snapshot_unavailable",
                "serviceRoute": "global"
            ]
        }

        var response: [String: Any] = [
            "ok": true,
            "isPro": snapshot["isPro"] as? Bool == true,
            "storeKitLocalPro": snapshot["storeKitLocalPro"] as? Bool == true,
            "serverPro": snapshot["serverPro"] as? Bool == true,
            "updatedAt": snapshot["updatedAt"] as? Double ?? 0,
            "serviceRoute": activeRoute
        ]
        for key in ["plan", "deviceId", "email", "userId"] {
            if let value = snapshot[key] as? String, !value.isEmpty {
                response[key] = value
            }
        }
        return response
    }

    /// Bearer access is a separate, route-bound contract used by the extension
    /// background proxy. It is never included in GET_ENTITLEMENT and must not
    /// be persisted in WebExtension storage or returned to content scripts.
    private func mobileSessionSnapshot(expectedRoute: String?) -> [String: Any] {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            return ["ok": false, "error": "app_group_unavailable", "serviceRoute": "global"]
        }
        let activeRoute = normalizedPersistedRoute(defaults.string(forKey: "serviceRoute"))
        guard let expectedRoute, isCurrentRouteValue(expectedRoute) else {
            return [
                "ok": false,
                "error": "expected_service_route_required",
                "serviceRoute": activeRoute
            ]
        }
        guard activeRoute == expectedRoute else {
            return [
                "ok": false,
                "error": "service_route_changed_restart_required",
                "serviceRoute": activeRoute
            ]
        }
        let snapshotKey = snapshotKeyPrefix + activeRoute
        guard let activeAccountStorageID = activeAccountStorageID(in: defaults) else {
            return [
                "ok": false,
                "error": "account_scope_unavailable",
                "serviceRoute": activeRoute
            ]
        }
        guard let snapshot = defaults.dictionary(forKey: snapshotKey),
              snapshot["serviceRoute"] as? String == activeRoute,
              snapshot["accountStorageID"] as? String == activeAccountStorageID else {
            return [
                "ok": false,
                "error": "entitlement_snapshot_unavailable",
                "serviceRoute": activeRoute
            ]
        }
        guard let token = readMobileSession(for: activeRoute) else {
            return [
                "ok": false,
                "error": "mobile_session_unavailable",
                "serviceRoute": activeRoute
            ]
        }
        return [
            "ok": true,
            "serviceRoute": activeRoute,
            "sessionToken": token
        ]
    }

    /// A server-side 401 can mean a well-formed `cms_` token has expired. The
    /// WebExtension background may ask the native boundary to exchange the
    /// route-scoped provider identity exactly once. Provider credentials never
    /// cross back into JavaScript; only the replacement cms_ token does, and it
    /// remains inside the background process.
    private func refreshMobileSession(
        _ context: NSExtensionContext,
        expectedRoute: String?
    ) {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            complete(
                context,
                response: [
                    "ok": false,
                    "error": "app_group_unavailable",
                    "serviceRoute": "global"
                ]
            )
            return
        }
        let activeRoute = normalizedPersistedRoute(defaults.string(forKey: "serviceRoute"))
        guard let expectedRoute, isCurrentRouteValue(expectedRoute) else {
            complete(
                context,
                response: [
                    "ok": false,
                    "error": "expected_service_route_required",
                    "serviceRoute": activeRoute
                ]
            )
            return
        }
        guard activeRoute == expectedRoute else {
            complete(
                context,
                response: [
                    "ok": false,
                    "error": "service_route_changed_restart_required",
                    "serviceRoute": activeRoute
                ]
            )
            return
        }
        let snapshotKey = snapshotKeyPrefix + activeRoute
        guard let activeAccountStorageID = activeAccountStorageID(in: defaults) else {
            complete(
                context,
                response: [
                    "ok": false,
                    "error": "account_scope_unavailable",
                    "serviceRoute": activeRoute
                ]
            )
            return
        }
        guard let snapshot = defaults.dictionary(forKey: snapshotKey),
              snapshot["serviceRoute"] as? String == activeRoute,
              snapshot["accountStorageID"] as? String == activeAccountStorageID else {
            complete(
                context,
                response: [
                    "ok": false,
                    "error": "entitlement_snapshot_unavailable",
                    "serviceRoute": activeRoute
                ]
            )
            return
        }
        guard let accessGroup = sharedKeychainAccessGroup(),
              let provider = readKeychainString(
                  account: routeScopedAccount(sessionProviderAccount, route: activeRoute),
                  accessGroup: accessGroup
              ),
              ["google", "apple", "email"].contains(provider),
              let identityToken = readKeychainString(
                  account: routeScopedAccount(sessionIdentityTokenAccount, route: activeRoute),
                  accessGroup: accessGroup
              ),
              !identityToken.isEmpty,
              identityToken.count <= 16_384 else {
            complete(
                context,
                response: [
                    "ok": false,
                    "error": "mobile_session_refresh_unavailable",
                    "serviceRoute": activeRoute
                ]
            )
            return
        }

        let gateway = activeRoute == "cn"
            ? "https://api.castreader.cn"
            : "https://api.castreader.ai"
        guard let endpoint = URL(string: gateway + "/api/mobile-auth/session") else {
            complete(
                context,
                response: [
                    "ok": false,
                    "error": "mobile_session_refresh_unavailable",
                    "serviceRoute": activeRoute
                ]
            )
            return
        }
        var body: [String: Any] = [
            "provider": provider,
            "idToken": identityToken
        ]
        if let deviceId = snapshot["deviceId"] as? String,
           !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["deviceId"] = deviceId
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            complete(
                context,
                response: [
                    "ok": false,
                    "error": "mobile_session_refresh_unavailable",
                    "serviceRoute": activeRoute
                ]
            )
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: SafariRejectRedirectDelegate(),
            delegateQueue: nil
        )
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let self else { return }
            let fail: (String) -> Void = { code in
                self.complete(
                    context,
                    response: [
                        "ok": false,
                        "error": code,
                        "serviceRoute": activeRoute
                    ]
                )
            }
            guard error == nil,
                  let data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  self.isExactGatewayResponse(http.url, route: activeRoute),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseData = root["data"] as? [String: Any],
                  let token = (responseData["token"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  self.isServerSessionToken(token) else {
                fail("mobile_session_refresh_unavailable")
                return
            }

            // Do not write a token if the containing app switched its frozen
            // route while this exchange was in flight.
            guard let latestDefaults = UserDefaults(suiteName: self.appGroup),
                  self.normalizedPersistedRoute(
                      latestDefaults.string(forKey: "serviceRoute")
                  ) == activeRoute,
                  self.activeAccountStorageID(in: latestDefaults)
                    == activeAccountStorageID,
                  latestDefaults.dictionary(forKey: snapshotKey)?["accountStorageID"]
                    as? String == activeAccountStorageID else {
                fail("service_route_changed_restart_required")
                return
            }
            let account = activeRoute == "cn"
                ? self.chinaSessionAccount
                : self.globalSessionAccount
            guard self.writeKeychainString(
                token,
                account: account,
                accessGroup: accessGroup
            ) else {
                fail("mobile_session_refresh_unavailable")
                return
            }
            self.complete(
                context,
                response: [
                    "ok": true,
                    "serviceRoute": activeRoute,
                    "sessionToken": token
                ]
            )
        }
        task.resume()
    }

    /// This handler intentionally reads exactly one route-scoped item and does
    /// not import the app's generic KeychainStore or enumerate the access group.
    private func readMobileSession(for route: String) -> String? {
        guard let accessGroup = sharedKeychainAccessGroup() else { return nil }
        let account = route == "cn" ? chinaSessionAccount : globalSessionAccount
        guard let token = readKeychainString(account: account, accessGroup: accessGroup),
              isServerSessionToken(token) else { return nil }
        return token
    }

    private func sharedKeychainAccessGroup() -> String? {
        guard let accessGroup = Bundle.main.object(
            forInfoDictionaryKey: keychainAccessGroupInfoKey
        ) as? String,
              !accessGroup.isEmpty,
              !accessGroup.contains("$("),
              accessGroup.hasSuffix(".com.same.castreader") else { return nil }
        return accessGroup
    }

    private func routeScopedAccount(_ base: String, route: String) -> String {
        route == "cn" ? base + ".cn" : base
    }

    private func activeAccountStorageID(in defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: activeAccountStorageIDKey),
              value.count == 64,
              value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private func readKeychainString(account: String, accessGroup: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func writeKeychainString(
        _ value: String,
        account: String,
        accessGroup: String
    ) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let add = SecItemAdd(item as CFDictionary, nil)
        if add == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                == errSecSuccess
        }
        return add == errSecSuccess
    }

    private func isServerSessionToken(_ token: String) -> Bool {
        token.hasPrefix("cms_")
            && !token.hasPrefix("cms_local_")
            && token.count > 4
            && token.count <= 4_096
    }

    private func isExactGatewayResponse(_ url: URL?, route: String) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443 else { return false }
        let expectedHost = route == "cn" ? "api.castreader.cn" : "api.castreader.ai"
        return components.host?.lowercased() == expectedHost
    }

    private func isCurrentRouteValue(_ rawValue: String) -> Bool {
        rawValue == "global" || rawValue == "cn"
    }

    /// Local migration only. Native messages and backend payloads never expose
    /// or accept the previous testing value `legacy`.
    private func normalizedPersistedRoute(_ rawValue: String?) -> String {
        switch rawValue {
        case "cn": return "cn"
        case "global", "legacy": return "global"
        default: return "global"
        }
    }

    private func complete(_ context: NSExtensionContext, response: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item])
    }
}

private final class SafariRejectRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
