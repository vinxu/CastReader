//
//  AuthService+Apple.swift
//  CastReader
//
//  Sign in with Apple（App Store 4.8 合规）。用 SwiftUI SignInWithAppleButton 触发，
//  这里处理授权结果 → UserAccount。需 entitlement com.apple.developer.applesignin。
//

import Foundation
import AuthenticationServices

/// Apple 首次授权返回的 name/email 的本地存档，按 Apple user id 索引。
///
/// Apple **只在第一次授权时**返回姓名和邮箱，之后每次登录都只给 user id——官方要求
/// app 自己把首次返回的资料存下来。原先只靠内存里的旧 `account` 回退，一旦登出
/// （`signOut()` 清掉 account）就永久丢失：显示名变成「?」，更要命的是 **email 也丢**，
/// 而 `ProManager.refreshServer` 是 email-primary，跨平台 Pro 会查不到。
///
/// 因此这份存档**独立于 account，登出时不清除**；按 user id 索引，换 Apple 账号不串号。
private let appleProfileArchiveKey = "apple_profile_archive_v1"

extension AuthService {
    /// 处理 Apple 授权结果。返回是否成功。
    func handleAppleAuthorization(_ authorization: ASAuthorization) async -> Bool {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else { return false }

        let id = cred.user
        // Apple 仅首次返回 email/name。三级回退：本次授权 → 当前内存账号 → 本地存档。
        // 存档这一级是登出后再登录的唯一来源（见 appleProfileArchiveKey）。
        let prior = account?.id == id ? account : nil
        let archived = Self.archivedAppleProfile(for: id)
        let email = cred.email ?? prior?.email ?? archived.email
        let nameParts = [cred.fullName?.givenName, cred.fullName?.familyName].compactMap { $0 }
        let name = nameParts.isEmpty ? (prior?.name ?? archived.name) : nameParts.joined(separator: " ")

        // 拿到什么就存什么：这是 Apple 唯一一次给资料的机会，错过不再有。
        Self.archiveAppleProfile(id: id, name: name, email: email)

        var acc = UserAccount(id: id, email: email, name: name, pictureURL: nil,
                              provider: "apple", backendUserId: prior?.backendUserId ?? archived.backendUserId)

        // best-effort：把 Apple identity token 发给 better-auth 换 user id
        if let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) {
            acc.backendUserId = await exchangeAppleIdentityToken(token) ?? prior?.backendUserId
            _ = try? await MobileSessionStore.shared.exchange(provider: "apple", idToken: token)
        }

        // backendUserId 换到了就一并存档，省得下次登录又退回 device_id 维度查 Pro。
        Self.archiveAppleProfile(id: id, name: name, email: email, backendUserId: acc.backendUserId)

        applyAccount(acc)
        await ProManager.shared.refreshServer()
        return true
    }

    // MARK: - Apple 资料存档

    static func archivedAppleProfile(
        for id: String
    ) -> (name: String?, email: String?, backendUserId: String?) {
        let all = UserDefaults.standard
            .dictionary(forKey: appleProfileArchiveKey) as? [String: [String: String]]
        let entry = all?[id]
        return (entry?["name"], entry?["email"], entry?["backendUserId"])
    }

    /// 只增不减：传 nil 不会擦掉已存的值——Apple 后续登录本来就全是 nil，
    /// 用它覆盖等于把首次拿到的资料丢了。
    static func archiveAppleProfile(
        id: String,
        name: String?,
        email: String?,
        backendUserId: String? = nil
    ) {
        guard !id.isEmpty else { return }
        let defaults = UserDefaults.standard
        var all = (defaults.dictionary(forKey: appleProfileArchiveKey)
            as? [String: [String: String]]) ?? [:]
        var entry = all[id] ?? [:]
        if let name, !name.isEmpty { entry["name"] = name }
        if let email, !email.isEmpty { entry["email"] = email }
        if let backendUserId, !backendUserId.isEmpty { entry["backendUserId"] = backendUserId }
        guard !entry.isEmpty else { return }
        all[id] = entry
        defaults.set(all, forKey: appleProfileArchiveKey)
    }

    /// Apple 的 identity token 只在这一次授权回调里存在，而且是短期 JWT——换不到后端
    /// user id 就没有第二次机会：不像 Google 能从 Keychain 取回 id_token 重试（见
    /// `ensureBackendUserIdForPro`），Apple 用户只能重新走一遍登录。所以趁 token 还
    /// 有效时多试几次，别让一次网络抖动变成永久的 `backendUserId == nil`——那会让
    /// Pro 查询退回 device_id 维度，Web 端付费和换设备的订阅都查不到。
    private func exchangeAppleIdentityToken(_ token: String) async -> String? {
        let backoff: [UInt64] = [0, 700_000_000, 1_800_000_000]
        for delay in backoff {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if let id = try? await exchangeWithBackend(provider: "apple", idToken: token),
               !id.isEmpty {
                return id
            }
        }
        return nil
    }
}
