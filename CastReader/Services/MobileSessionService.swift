import Foundation

protocol MobileSessionProviding: Sendable {
    func sessionToken() async -> String?
    func refreshSession() async -> String?
    func invalidateSession() async
}

actor MobileSessionStore: MobileSessionProviding {
    static let shared = MobileSessionStore()
    static let keychainKey = "castreader_mobile_session_v1"
    private static let providerKey = "castreader_mobile_session_provider_v1"
    private static let identityTokenKey = "castreader_mobile_identity_token_v1"

    private let overrideEndpoint: URL?
    private let session: URLSession

    /// 会话端点跟随发行区域（中国区后端就绪前仍是 castreader.ai，见
    /// `Constants.Features.chinaBackendEnabled`）。因此按需计算而不是在 init 固化。
    private var endpoint: URL {
        overrideEndpoint
            ?? URL(string: Constants.API.webURL + "/api/mobile-auth/session")
            ?? URL(string: "https://castreader.ai/api/mobile-auth/session")!
    }

    init(
        endpoint: URL? = nil,
        session: URLSession = .shared
    ) {
        self.overrideEndpoint = endpoint
        self.session = session
    }

    func sessionToken() -> String? { normalized(KeychainStore.get(Self.keychainKey)) }

    @discardableResult
    func exchange(provider: String, idToken: String, deviceId: String = StableDeviceID.current) async throws -> String {
        guard provider == "google" || provider == "apple", !idToken.trimmed.isEmpty else {
            throw VoiceCloneError.signInRequired
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": provider,
            "idToken": idToken,
            "deviceId": deviceId,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceCloneError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw VoiceCloneError.server(http.statusCode, VoiceCloneResponseParser.serverMessage(from: data))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let token = normalized(payload["token"] as? String), token.hasPrefix("cms_") else {
            throw VoiceCloneError.invalidResponse
        }
        KeychainStore.set(token, for: Self.keychainKey)
        KeychainStore.set(provider, for: Self.providerKey)
        KeychainStore.set(idToken, for: Self.identityTokenKey)
        return token
    }

    /// 收下由其他登录方式（中国区手机号）直接下发的会话 token。
    ///
    /// 手机号登录没有 idToken 可换，服务端在校验验证码时就把 session 发下来了。
    /// 这类会话无法本地续期，过期后需要用户重新登录（`refreshSession` 因此返回 nil）。
    func adoptExternalSession(token: String, provider: String) {
        guard let token = normalized(token) else { return }
        KeychainStore.set(token, for: Self.keychainKey)
        KeychainStore.set(provider, for: Self.providerKey)
        KeychainStore.delete(Self.identityTokenKey)
    }

    func refreshSession() async -> String? {
        guard let provider = normalized(KeychainStore.get(Self.providerKey)),
              let idToken = normalized(KeychainStore.get(Self.identityTokenKey)) else { return nil }
        return try? await exchange(provider: provider, idToken: idToken)
    }

    func invalidateSession() async {
        if let token = sessionToken() {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
            _ = try? await session.data(for: request)
        }
        KeychainStore.delete(Self.keychainKey)
        KeychainStore.delete(Self.providerKey)
        KeychainStore.delete(Self.identityTokenKey)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmed, !value.isEmpty else { return nil }
        return value
    }
}

struct MissingMobileSessionProvider: MobileSessionProviding {
    func sessionToken() async -> String? { nil }
    func refreshSession() async -> String? { nil }
    func invalidateSession() async {}
}
