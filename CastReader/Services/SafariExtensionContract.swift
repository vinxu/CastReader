import Foundation
import Security

/// Shared by the App and Safari target. OAuth/provider credentials remain in
/// the App's private keychain; this separate group contains only a cms_ bearer
/// bound to the currently published route, account and login boundary.
struct SafariSessionEnvelope: Codable, Equatable {
    let route: String
    let accountStorageID: String
    let boundaryNonce: String
    let sessionToken: String

    /// The extension cannot renew OAuth credentials. A 401 retry may only
    /// adopt a different bearer that the containing App has already renewed.
    func tokenForRequest(refresh: Bool, rejectedToken: String?) -> String? {
        guard !refresh || (rejectedToken?.hasPrefix("cms_") == true
                           && rejectedToken != sessionToken) else { return nil }
        return sessionToken
    }

    func matches(route: String, accountStorageID: String, boundaryNonce: String) -> Bool {
        ["global", "cn"].contains(route)
            && SafariExtensionContract.validAccount(accountStorageID) != nil
            && !boundaryNonce.isEmpty
            && self.route == route && self.accountStorageID == accountStorageID
            && self.boundaryNonce == boundaryNonce
            && sessionToken.hasPrefix("cms_") && !sessionToken.hasPrefix("cms_local_")
            && sessionToken.count > 4 && sessionToken.count <= 4_096
    }
}

enum SafariExtensionContract {
    static let appGroup = "group.com.same.castreader"
    static let snapshotPrefix = "entitlementSnapshot.v3."
    static let accountKey = "account.content.activeStorageID.v1"
    static let nonceKey = "account.content.activeBoundaryNonce.v1"

    static func route(_ raw: String?) -> String { raw == "cn" ? "cn" : "global" }

    static func validAccount(_ value: String?) -> String? {
        guard let value, value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    static func matches(_ snapshot: [String: Any], route: String, account: String, nonce: String) -> Bool {
        !nonce.isEmpty && snapshot["serviceRoute"] as? String == route
            && snapshot["accountStorageID"] as? String == account
            && snapshot["boundaryNonce"] as? String == nonce
    }

    /// Background-only identity, taken from the same scope-checked projection
    /// as the bearer. Provider subjects and profile email are never owner keys.
    static func sessionIdentity(_ snapshot: [String: Any]) -> [String: Any]? {
        guard let userID = snapshot["userId"] as? String,
              !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, userID.count <= 512,
              let account = validAccount(snapshot["accountStorageID"] as? String),
              let nonce = snapshot["boundaryNonce"] as? String, !nonce.isEmpty, nonce.count <= 512 else { return nil }
        return ["canonicalAccountId": userID, "accountStorageID": account, "boundaryNonce": nonce,
                "email": snapshot["email"] as? String ?? ""]
    }

    /// Deliberately whitelist the public fields. Secure session data can never
    /// enter the entitlement response consumed by content scripts.
    static func entitlement(_ snapshot: [String: Any], route: String) -> [String: Any] {
        var result: [String: Any] = ["ok": true, "serviceRoute": route]
        for key in ["isPro", "storeKitLocalPro", "serverPro"] {
            result[key] = snapshot[key] as? Bool == true
        }
        for key in ["plan", "deviceId", "email", "userId"] {
            if let value = snapshot[key] as? String, !value.isEmpty { result[key] = value }
        }
        result["updatedAt"] = snapshot["updatedAt"] as? Double ?? 0
        return result
    }
}

enum SafariHandoffAction: String {
    case account, pro, signOut
}

/// A Safari URL only redeems a short-lived, locally issued navigation intent.
/// Arbitrary websites cannot sign out the App by constructing an account URL.
enum SafariAppHandoff {
    private static let key = "safari.appHandoff.v1"

    static func issue(_ action: SafariHandoffAction, route: String, defaults: UserDefaults,
                      now: Date = Date()) -> URL? {
        guard ["global", "cn"].contains(route),
              SafariExtensionContract.route(defaults.string(forKey: "serviceRoute")) == route else { return nil }
        let account = defaults.string(forKey: SafariExtensionContract.accountKey) ?? ""
        let boundary = defaults.string(forKey: SafariExtensionContract.nonceKey) ?? ""
        if action == .signOut && (SafariExtensionContract.validAccount(account) == nil || boundary.isEmpty) {
            return nil
        }
        let requestID = UUID().uuidString
        defaults.set(["requestID": requestID, "action": action.rawValue, "route": route,
                      "account": account, "boundary": boundary, "issuedAt": now.timeIntervalSince1970], forKey: key)
        guard defaults.synchronize() else { return nil }
        var url = URLComponents()
        url.scheme = "castreader"
        url.host = "safari"
        url.queryItems = [URLQueryItem(name: "request", value: requestID)]
        return url.url
    }

    static func consume(_ url: URL, route: String, defaults: UserDefaults,
                        now: Date = Date()) -> SafariHandoffAction? {
        guard url.scheme == "castreader", url.host == "safari", url.path.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "request", let requestID = items[0].value,
              let pending = defaults.dictionary(forKey: key),
              pending["requestID"] as? String == requestID else { return nil }
        defaults.removeObject(forKey: key)
        defaults.synchronize()
        guard let issuedAt = pending["issuedAt"] as? Double,
              now.timeIntervalSince1970 >= issuedAt, now.timeIntervalSince1970 - issuedAt <= 120,
              pending["route"] as? String == route,
              SafariExtensionContract.route(defaults.string(forKey: "serviceRoute")) == route,
              pending["account"] as? String == (defaults.string(forKey: SafariExtensionContract.accountKey) ?? ""),
              pending["boundary"] as? String == (defaults.string(forKey: SafariExtensionContract.nonceKey) ?? ""),
              let raw = pending["action"] as? String else { return nil }
        return SafariHandoffAction(rawValue: raw)
    }
}

enum SafariSharedSessionStore {
    private static let service = "ai.castreader.safari-session"

    private static func query(route: String) -> [String: Any]? {
        guard ["global", "cn"].contains(route),
              let group = Bundle.main.object(forInfoDictionaryKey: "CastReaderSafariKeychainAccessGroup") as? String,
              !group.contains("$("), group.hasSuffix(".com.same.castreader.safari") else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session.v1." + route,
            kSecAttrAccessGroup as String: group
        ]
    }

    static func read(route: String) -> SafariSessionEnvelope? {
        guard var query = query(route: route) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SafariSessionEnvelope.self, from: data)
    }

    @discardableResult
    static func write(_ envelope: SafariSessionEnvelope) -> Bool {
        guard envelope.matches(route: envelope.route, accountStorageID: envelope.accountStorageID,
                               boundaryNonce: envelope.boundaryNonce),
              let query = query(route: envelope.route),
              let data = try? JSONEncoder().encode(envelope) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    static func remove(route: String) {
        guard let query = query(route: route) else { return }
        SecItemDelete(query as CFDictionary)
    }
}
