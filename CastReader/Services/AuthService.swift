//
//  AuthService.swift
//  CastReader
//
//  登录服务。Google 用原生 ASWebAuthenticationSession + PKCE（无第三方 SDK），
//  best-effort 把 Google id_token 换成 better-auth 后端 user id（用于按账号查 Pro）。
//  Apple 登录见扩展（AuthService+Apple）。
//

import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import Combine

enum AuthError: Error, LocalizedError {
    case notConfigured
    case cancelled
    case invalidCallback
    case tokenExchangeFailed(String)
    case invalidIDToken
    case invalidEmail
    case emailOTPUnavailable
    case invalidOTP

    var errorDescription: String? {
        switch self {
        case .notConfigured: return AppLocalized("尚未配置 Google 登录")
        case .cancelled: return AppLocalized("已取消登录")
        case .invalidCallback: return AppLocalized("登录回调无效")
        case .tokenExchangeFailed(let m): return AppLocalized("登录失败：\(m)")
        case .invalidIDToken: return AppLocalized("无法解析登录信息")
        case .invalidEmail: return AppLocalized("请输入有效的邮箱地址")
        case .emailOTPUnavailable: return AppLocalized("邮箱登录暂未开放，请使用 Google 或 Apple 登录")
        case .invalidOTP: return AppLocalized("验证码错误或已过期，请重试")
        }
    }
}

@MainActor
final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    @Published private(set) var account: UserAccount?
    @Published var isWorking = false

    var isSignedIn: Bool { account != nil }
    var normalizedEmail: String? {
        guard let raw = account?.email else {
            return nil
        }
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return nil }
        return email
    }
    var hasEmailAccount: Bool { normalizedEmail != nil }

    /// 是否具备可跨设备同步 Pro 的账号身份。
    ///
    /// 全球版靠邮箱（Google/Apple 一定会给），但中国区手机号账号**没有邮箱**，
    /// 它拿到的是后端直接下发的 user id。把邮箱当作唯一判据会把所有手机号
    /// 用户挡在购买之外——付费按钮点不动、Pro 也同步不回来。
    ///
    /// 因此购买与同步类门禁一律用这个判据；只有「确实要把邮箱发给后端」的
    /// 地方才继续读 `normalizedEmail`。
    var hasSyncableAccount: Bool {
        if normalizedEmail != nil { return true }
        if let backendUserId = account?.backendUserId, !backendUserId.isEmpty { return true }
        return false
    }

    /// 查 Pro 用的账号 id：仅用后端 better-auth user id；关联失败时为 nil → Pro 查询退回 device_id 维度。
    /// 不回退 provider sub（account.id），因其与后端 user_id 不同命名空间，会查不到 Web 端付费的 Pro。
    var proUserId: String? { account?.backendUserId }

    /// Apple 登录未能关联后端 user id 的状态——需要用户重新登录一次才能修复。
    ///
    /// Apple 的 identity token 只在授权回调期间存在，`ensureBackendUserIdForPro()` 对
    /// Apple 账号无能为力（拿不到可重放的 token）。未关联时 Pro 只能按 device_id 查，
    /// 于是 Web 端（Stripe）付费和换过设备的订阅都会被当成未订阅。重新走一遍
    /// Sign in with Apple 会重新换取，是唯一的自救路径，所以要让用户看得见。
    var needsAppleRelink: Bool {
        guard let acc = account, acc.provider == "apple" else { return false }
        return (acc.backendUserId ?? "").isEmpty
    }

    private var webSession: ASWebAuthenticationSession?
    private let accountKey = "auth_account_v1"

    override private init() {
        super.init()
        restore()
    }

    // MARK: - 持久化

    func restore() {
        if let data = UserDefaults.standard.data(forKey: accountKey),
           let acc = try? JSONDecoder().decode(UserAccount.self, from: data) {
            account = acc
        }
    }

    private func persist() {
        if let acc = account, let data = try? JSONEncoder().encode(acc) {
            UserDefaults.standard.set(data, forKey: accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
    }

    func signOut() {
        account = nil
        AppSettings.shared.clearActiveClonedVoice()
        Task { await MobileSessionStore.shared.invalidateSession() }
        persist()
        KeychainStore.delete("google_id_token")
        KeychainStore.delete("google_access_token")
        KeychainStore.delete("betterauth_session_token")
        Task { @MainActor in
            ProManager.shared.clearServerEntitlement()   // 先本地清，避免 refreshServer 失败时 serverPro 滞留为 true
            await ProManager.shared.refreshServer()       // 再按 device_id 维度刷新
            ProManager.shared.refreshSyncState(reason: "sign-out")
        }
    }

    /// Migrates an already signed-in Google account into the first-party mobile
    /// session on demand. Apple identity tokens are only available during the
    /// authorization callback, so an older Apple login must sign in again.
    func ensureMobileSessionForVoiceClone() async -> Bool {
        guard Constants.Features.voiceCloningEnabled else { return false }
        if await MobileSessionStore.shared.sessionToken() != nil { return true }
        guard account?.provider == "google",
              let idToken = KeychainStore.get("google_id_token"), !idToken.isEmpty else { return false }
        return (try? await MobileSessionStore.shared.exchange(provider: "google", idToken: idToken)) != nil
    }

    /// 供 Apple 登录扩展写入账号（private(set) 仅本文件可设）。
    func applyAccount(_ acc: UserAccount) {
        account = acc
        persist()
    }

    /// 用服务端返回的资料补齐本地缺失的昵称/头像，**只填空不覆盖**。
    ///
    /// 两条路径拿不到完整资料：邮箱验证码登录（better-auth 响应常不带 name/image）
    /// 与 Apple 的二次登录（只有首次授权给资料）。它们和 Google 登录落在同一个后端
    /// 账号上，而 `/api/pro/status` 会回传 `account{name,email,image}`——用它回填，
    /// 用户就不会看到「同一个账号换个方式登进来就没头像了」。
    func fillMissingProfile(name: String?, pictureURL: String?) {
        guard var acc = account else { return }
        var changed = false
        if (acc.name ?? "").isEmpty, let name, !name.isEmpty {
            acc.name = name
            changed = true
        }
        if (acc.pictureURL ?? "").isEmpty, let pictureURL, !pictureURL.isEmpty {
            acc.pictureURL = pictureURL
            changed = true
        }
        guard changed else { return }
        account = acc
        persist()
    }

    // MARK: - 手机号登录（中国区）

    /// 手机号 + 短信验证码登录。
    ///
    /// 与 Google/Apple 的差别：后端直接下发 mobile session token 与 user id，
    /// 不需要再走 `exchangeWithBackend`。手机号本身只保留脱敏形式。
    func signInWithPhone(phone rawPhone: String, code: String) async throws {
        isWorking = true
        defer { isWorking = false }

        let result = try await PhoneAuthService.shared.verify(phone: rawPhone, code: code)
        await MobileSessionStore.shared.adoptExternalSession(
            token: result.sessionToken,
            provider: "phone"
        )

        let masked = ChinaPhoneNumber.masked(rawPhone)
        applyAccount(
            UserAccount(
                id: result.userId,
                email: nil,
                name: result.displayName,
                pictureURL: nil,
                provider: "phone",
                backendUserId: result.userId,
                maskedPhone: masked.isEmpty ? nil : masked
            )
        )

        // 登录后立刻按账号维度刷新 Pro，避免继续停留在 device_id 维度。
        ProManager.shared.refreshSyncState(reason: "phone-sign-in")
        await ProManager.shared.refresh()
    }

    /// 注销账号：先请求后端删除，再清空本地身份。
    ///
    /// 后端失败时**不**清本地——否则用户会以为已注销，实际数据还在。
    func deleteAccount() async throws {
        isWorking = true
        defer { isWorking = false }

        guard let token = await MobileSessionStore.shared.sessionToken() else {
            throw PhoneAuthError.server(status: 401, message: AppLocalized("请先重新登录后再注销账号"))
        }
        try await PhoneAuthService.shared.deleteAccount(sessionToken: token)
        signOut()
    }

    /// Pro 查询需要 readout-web / better-auth 的 user id。旧版本若登录时换取失败，
    /// 会持久化成 backendUserId=nil；刷新 Pro 前用已保存的 Google id_token 轻量重试一次。
    func ensureBackendUserIdForPro() async -> String? {
        guard var acc = account else { return nil }
        if let id = acc.backendUserId, !id.isEmpty { return id }
        guard acc.provider == "google",
              let idToken = KeychainStore.get("google_id_token"),
              !idToken.isEmpty else {
            return nil
        }
        do {
            guard let id = try await exchangeWithBackend(provider: "google", idToken: idToken),
                  !id.isEmpty else {
                return nil
            }
            acc.backendUserId = id
            account = acc
            persist()
            return id
        } catch {
            return nil
        }
    }

    // MARK: - Google 登录

    func signInWithGoogle() async throws {
        guard Constants.GoogleOAuth.isConfigured else { throw AuthError.notConfigured }
        isWorking = true
        defer { isWorking = false }

        let verifier = Self.randomURLSafe(32)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(16)

        let authURL = try buildGoogleAuthURL(challenge: challenge, state: state)
        let callbackURL = try await presentWebAuth(url: authURL, scheme: Constants.GoogleOAuth.reversedClientID)

        guard let code = Self.queryItem(callbackURL, "code"),
              Self.queryItem(callbackURL, "state") == state else {
            throw AuthError.invalidCallback
        }

        let tokens = try await exchangeGoogleCode(code, verifier: verifier)
        guard let idToken = tokens.id_token, let claims = Self.decodeJWTClaims(idToken) else {
            throw AuthError.invalidIDToken
        }

        var acc = UserAccount(
            id: (claims["sub"] as? String) ?? UUID().uuidString,
            email: claims["email"] as? String,
            name: claims["name"] as? String,
            pictureURL: claims["picture"] as? String,
            provider: "google",
            backendUserId: nil
        )
        KeychainStore.set(idToken, for: "google_id_token")
        if let at = tokens.access_token { KeychainStore.set(at, for: "google_access_token") }

        // best-effort：换后端 user id（失败不影响登录，Pro 退回 device_id）
        acc.backendUserId = try? await exchangeWithBackend(provider: "google", idToken: idToken)

        // Voice clone requires a first-party cms_ session. Login remains usable if
        // this exchange is temporarily unavailable; clone UI stays fail closed.
        _ = try? await MobileSessionStore.shared.exchange(provider: "google", idToken: idToken)

        account = acc
        persist()
        await ProManager.shared.refreshServer()   // 按账号刷新 Pro
    }

    // MARK: - 邮箱验证码登录（better-auth email-otp）
    //
    // 第三条登录通道：不依赖任何第三方授权服务（中国区 Google 不通时 Apple 之外的
    // 唯一冗余）。后端未启用 email-otp 插件时两个路由返回 404 → emailOTPUnavailable，
    // 插件上线后此通道自动点亮，无需发版。
    //
    // ⚠️ 只有这条链路打 castreader.com（`emailOTPBaseURL`）——插件装在那边，
    // 且 auth 的正式归属是 .com。两站共用同一个 Supabase，拿到的 user.id
    // 与 Google 登录换到的 backendUserId 属于同一命名空间，Pro 查询照常。
    //
    // Pro 一致性：登录响应里的 user.id 就是 better-auth user id，直接作为
    // backendUserId（无 social idToken 可换，也不需要）；email 一定存在，满足
    // refreshServer 的 email-primary 规则，Web 端 Stripe Pro 按 email 匹配。
    // 局限：/api/mobile-auth/session 目前只认 google/apple，邮箱账号换不到 cms_
    // 会话 → verify-apple 上报会跳过（needsEmailSync 如实显示“跨平台同步等待”）。

    /// 发送登录验证码。成功返回；失败抛 AuthError。
    func sendEmailOTP(to email: String) async throws {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isPlausibleEmail(normalized) else { throw AuthError.invalidEmail }
        isWorking = true
        defer { isWorking = false }
        _ = try await postEmailOTP(
            path: "email-otp/send-verification-otp",
            body: ["email": normalized, "type": "sign-in"]
        )
    }

    /// 用邮箱+验证码完成登录，成功后与 Google/Apple 一样刷新服务端 Pro。
    func signInWithEmailOTP(email: String, code: String) async throws {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isPlausibleEmail(normalized) else { throw AuthError.invalidEmail }
        let otp = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !otp.isEmpty else { throw AuthError.invalidOTP }
        isWorking = true
        defer { isWorking = false }

        let obj = try await postEmailOTP(
            path: "sign-in/email-otp",
            body: ["email": normalized, "otp": otp]
        )
        let user = obj["user"] as? [String: Any]
        guard let backendId = (user?["id"] as? String) ?? (obj["userId"] as? String),
              !backendId.isEmpty else {
            throw AuthError.invalidIDToken
        }

        // better-auth 会话 token：目前 mobile-auth 换不了 cms_ 会话用不上，但和
        // Apple identity token 一样只在这一刻拿得到——先存下来，后端支持后可
        // 直接补换会话，不用逼用户重新登录（见 needsAppleRelink 的教训）。
        if let token = obj["token"] as? String, !token.isEmpty {
            KeychainStore.set(token, for: "betterauth_session_token")
        }

        // 同一个后端账号可能之前用 Google 登过（email-otp 按 email 命中同一条 user
        // 记录，backendUserId 相同）。better-auth 的登录响应常常不带 name/image，
        // 直接采用会把已有的头像和昵称覆盖成空。所以缺什么就沿用旧账号的。
        let prior = account?.backendUserId == backendId ? account : nil
        account = UserAccount(
            id: backendId,
            email: (user?["email"] as? String) ?? normalized,
            name: (user?["name"] as? String) ?? prior?.name,
            pictureURL: (user?["image"] as? String) ?? prior?.pictureURL,
            provider: "email",
            backendUserId: backendId
        )
        persist()
        await ProManager.shared.refreshServer()   // 按账号刷新 Pro + 额度
    }

    /// better-auth email-otp 的两个 POST。404 = 插件未启用；sign-in 的 400/401 = 验证码错。
    private func postEmailOTP(path: String, body: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: "\(Constants.API.emailOTPBaseURL)/api/auth/\(path)") else {
            throw AuthError.tokenExchangeFailed("invalid endpoint")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.tokenExchangeFailed("no response")
        }
        switch http.statusCode {
        case 200..<300:
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case 404:
            throw AuthError.emailOTPUnavailable
        case 400, 401, 403:
            throw AuthError.invalidOTP
        default:
            throw AuthError.tokenExchangeFailed("HTTP \(http.statusCode)")
        }
    }

    private static func isPlausibleEmail(_ s: String) -> Bool {
        guard s.count >= 5, s.count <= 254 else { return false }
        let parts = s.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty
    }

    // MARK: - Google OAuth 细节

    private func buildGoogleAuthURL(challenge: String, state: String) throws -> URL {
        var comps = URLComponents(string: Constants.GoogleOAuth.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: Constants.GoogleOAuth.clientID),
            .init(name: "redirect_uri", value: Constants.GoogleOAuth.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Constants.GoogleOAuth.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account")
        ]
        guard let url = comps.url else { throw AuthError.notConfigured }
        return url
    }

    private struct GoogleTokenResponse: Decodable {
        let access_token: String?
        let id_token: String?
        let expires_in: Int?
        let refresh_token: String?
    }

    private func exchangeGoogleCode(_ code: String, verifier: String) async throws -> GoogleTokenResponse {
        guard let url = URL(string: Constants.GoogleOAuth.tokenEndpoint) else {
            throw AuthError.tokenExchangeFailed("invalid token endpoint")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form: [String: String] = [
            "code": code,
            "client_id": Constants.GoogleOAuth.clientID,
            "redirect_uri": Constants.GoogleOAuth.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ]
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }

    /// 把社交 id_token 发给 better-auth，换取后端 user id（best-effort）。
    func exchangeWithBackend(provider: String, idToken: String) async throws -> String? {
        guard let url = URL(string: Constants.API.authSocialSignIn) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "provider": provider,
            "idToken": ["token": idToken],
            "device_id": ProBackendService.deviceId
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let user = obj["user"] as? [String: Any], let id = user["id"] as? String { return id }
        if let id = obj["userId"] as? String { return id }
        return nil
    }

    // MARK: - ASWebAuthenticationSession

    private func presentWebAuth(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let error = error {
                    let nsErr = error as NSError
                    if nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: AuthError.cancelled)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard let callback = callback else { cont.resume(throwing: AuthError.invalidCallback); return }
                cont.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start() {
                cont.resume(throwing: AuthError.cancelled)
            }
        }
    }

    // MARK: - PKCE / JWT 工具

    static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return base64URL(Data(buf))
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func queryItem(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}

// MARK: - 呈现锚点

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            return window ?? ASPresentationAnchor()
        }
    }
}
