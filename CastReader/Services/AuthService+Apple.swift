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
            acc.backendUserId = (try? await exchangeWithBackend(provider: "apple", idToken: token)) ?? prior?.backendUserId
        }

        applyAccount(acc)
        await ProManager.shared.refreshServer()
        return true
    }
}
