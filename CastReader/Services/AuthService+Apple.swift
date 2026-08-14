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
/// （`signOut()` 清掉 account）就永久丢失：显示名变成「?」，首次返回的账号资料
/// 也无法再恢复。跨平台 Pro 以 canonical backend user id 为主，email 只作为兼容线索。
///
/// 因此这份存档**独立于 account，登出时不清除**；按 user id 索引，换 Apple 账号不串号。
private let appleProfileArchiveKey = "apple_profile_archive_v1"

extension AuthService {
    /// 处理 Apple 授权结果。返回是否成功。
    func handleAppleAuthorization(_ authorization: ASAuthorization) async -> Bool {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else { return false }
        isWorking = true
        defer { isWorking = false }

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

        // Apple authorization code 只在授权回调中出现且只能使用一次。与
        // identity token 一起送到所选一方网关，由服务端换取并安全保存 refresh
        // token，后续账号删除时才能调用 Apple `/auth/revoke`。code 不在端上落盘。
        let authorizationCode = cred.authorizationCode
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Apple 本地授权不等于 CastReader 后端登录。必须先在
        // 当前线路换到并持久化 cms_ session，才能发布新账号；
        // 否则会出现 UI 显示 Apple 已登录，而文库/解读仍带旧会话或无会话。
        guard let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              !token.trimmed.isEmpty else {
            return false
        }
        do {
            _ = try await MobileSessionStore.shared.exchange(
                provider: "apple",
                idToken: token,
                authorizationCode: authorizationCode
            )
        } catch {
            return false
        }

        // canonical user id 用于跨端 Pro 归属；它的辅助换取失败不会
        // 降级 cms_ 会话，后续仍可用同一 identity token 重试。
        acc.backendUserId = await exchangeAppleIdentityToken(token) ?? prior?.backendUserId

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
        return (
            entry?["name"],
            entry?["email"],
            entry?[appleBackendUserIdField(for: ServiceRouting.current)]
        )
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
        if let backendUserId, !backendUserId.isEmpty {
            entry[appleBackendUserIdField(for: ServiceRouting.current)] = backendUserId
        }
        guard !entry.isEmpty else { return }
        all[id] = entry
        defaults.set(all, forKey: appleProfileArchiveKey)
    }

    /// Account deletion and Apple credential revocation are different from a
    /// normal sign-out: Apple requires user-related local data to be removed.
    /// Delete the entire user entry so data cannot leak between service routes.
    static func removeArchivedAppleProfile(for id: String) {
        guard !id.isEmpty else { return }
        let defaults = UserDefaults.standard
        var all = (defaults.dictionary(forKey: appleProfileArchiveKey)
            as? [String: [String: String]]) ?? [:]
        guard all.removeValue(forKey: id) != nil else { return }
        if all.isEmpty {
            defaults.removeObject(forKey: appleProfileArchiveKey)
        } else {
            defaults.set(all, forKey: appleProfileArchiveKey)
        }
    }

    // MARK: - Apple credential lifecycle

    /// Register once for the native revocation signal. The callback performs
    /// no account work on the posting thread and rechecks the current account
    /// on MainActor before clearing anything.
    func startAppleCredentialMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppleCredentialRevokedNotification(_:)),
            name: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil
        )
    }

    @objc nonisolated private func handleAppleCredentialRevokedNotification(
        _ notification: Notification
    ) {
        Task { @MainActor [weak self] in
            guard let self, let id = self.currentAppleUserID else { return }
            self.clearRevokedAppleCredential(expectedUserID: id)
        }
    }

    /// Foreground checks also catch Apple Account deletion, for which the
    /// native revoked notification is not guaranteed. Network/provider errors
    /// return nil and leave the local account intact rather than causing a
    /// false sign-out.
    func refreshAppleCredentialState() async {
        guard let id = currentAppleUserID else { return }
        let state = await withCheckedContinuation {
            (continuation: CheckedContinuation<ASAuthorizationAppleIDProvider.CredentialState?, Never>) in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: id) { state, error in
                continuation.resume(returning: error == nil ? state : nil)
            }
        }
        guard let state, Self.appleCredentialRequiresLocalSignOut(state) else { return }
        clearRevokedAppleCredential(expectedUserID: id)
    }

    static func appleCredentialRequiresLocalSignOut(
        _ state: ASAuthorizationAppleIDProvider.CredentialState
    ) -> Bool {
        switch state {
        case .authorized:
            return false
        case .revoked, .notFound, .transferred:
            return true
        @unknown default:
            return true
        }
    }

    private var currentAppleUserID: String? {
        guard let account, account.provider == "apple", !account.id.isEmpty else { return nil }
        return account.id
    }

    private func clearRevokedAppleCredential(expectedUserID: String) {
        guard currentAppleUserID == expectedUserID else { return }
        Self.removeArchivedAppleProfile(for: expectedUserID)
        signOut()
    }

    static func appleBackendUserIdField(for route: ServiceRoute) -> String {
        switch route {
        case .globalGateway: return "backendUserId"
        case .chinaGateway: return "backendUserId_cn"
        }
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
