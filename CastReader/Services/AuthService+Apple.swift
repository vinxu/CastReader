//
//  AuthService+Apple.swift
//  CastReader
//
//  Sign in with Apple（App Store 4.8 合规）。用 SwiftUI SignInWithAppleButton 触发，
//  这里处理授权结果 → UserAccount。需 entitlement com.apple.developer.applesignin。
//

import Foundation
import AuthenticationServices

extension AuthService {
    /// 处理 Apple 授权结果。返回是否成功。
    func handleAppleAuthorization(_ authorization: ASAuthorization) async -> Bool {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else { return false }

        let id = cred.user
        // Apple 仅首次返回 email/name；后续复用已存账号资料
        let prior = account?.id == id ? account : nil
        let email = cred.email ?? prior?.email
        let nameParts = [cred.fullName?.givenName, cred.fullName?.familyName].compactMap { $0 }
        let name = nameParts.isEmpty ? prior?.name : nameParts.joined(separator: " ")

        var acc = UserAccount(id: id, email: email, name: name, pictureURL: nil,
                              provider: "apple", backendUserId: prior?.backendUserId)

        // best-effort：把 Apple identity token 发给 better-auth 换 user id
        if let tokenData = cred.identityToken, let token = String(data: tokenData, encoding: .utf8) {
            acc.backendUserId = await exchangeAppleIdentityToken(token) ?? prior?.backendUserId
            _ = try? await MobileSessionStore.shared.exchange(provider: "apple", idToken: token)
        }

        applyAccount(acc)
        await ProManager.shared.refreshServer()
        return true
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
