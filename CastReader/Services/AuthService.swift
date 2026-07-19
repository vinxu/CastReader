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

    var errorDescription: String? {
        switch self {
        case .notConfigured: return AppLocalized("尚未配置 Google 登录")
        case .cancelled: return AppLocalized("已取消登录")
        case .invalidCallback: return AppLocalized("登录回调无效")
        case .tokenExchangeFailed(let m): return AppLocalized("登录失败：\(m)")
        case .invalidIDToken: return AppLocalized("无法解析登录信息")
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

    /// 查 Pro 用的账号 id：仅用后端 better-auth user id；关联失败时为 nil → Pro 查询退回 device_id 维度。
    /// 不回退 provider sub（account.id），因其与后端 user_id 不同命名空间，会查不到 Web 端付费的 Pro。
    var proUserId: String? { account?.backendUserId }

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
