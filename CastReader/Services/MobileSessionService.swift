import Foundation

protocol MobileSessionProviding: Sendable {
    func sessionToken() async -> String?
    func refreshSession() async -> String?
    func invalidateSession() async
    func rejectSession(_ rejectedToken: String?) async
}

extension MobileSessionProviding {
    /// Test doubles and deliberately missing-session providers do not own the
    /// app's authenticated UI state. The production MobileSessionStore
    /// overrides this hook and closes the local account boundary.
    func rejectSession(_ rejectedToken: String?) async {}
}

/// Process-local generation clock for account credential boundaries.
///
/// Actors are reentrant while awaiting URLSession. Without an independent
/// generation, an account-A refresh that started before sign-out could finish
/// after account B logged in and overwrite B's bearer. All credential writes
/// and synchronous sign-out detaches are serialized here; a response may only
/// persist if the route generation it started in is still current.
private final class MobileSessionBoundaryClock: @unchecked Sendable {
    static let shared = MobileSessionBoundaryClock()

    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]

    func snapshot(for route: ServiceRoute) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generations[route.rawValue, default: 0]
    }

    func isCurrent(_ generation: UInt64, for route: ServiceRoute) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[route.rawValue, default: 0] == generation
    }

    func advanceAndPerform<T>(for route: ServiceRoute, _ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        generations[route.rawValue, default: 0] &+= 1
        return body()
    }

    func performIfCurrent<T>(
        _ generation: UInt64,
        for route: ServiceRoute,
        _ body: () -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard generations[route.rawValue, default: 0] == generation else {
            return nil
        }
        return body()
    }
}

actor MobileSessionStore: MobileSessionProviding {
    static let shared = MobileSessionStore()
    /// 保留历史常量供升级迁移；globalGateway 继续读原 key，CN 使用独立 key。
    static let keychainKey = "castreader_mobile_session_v1"
    private static let providerKey = "castreader_mobile_session_provider_v1"
    private static let identityTokenKey = "castreader_mobile_identity_token_v1"

    struct StorageKeys: Equatable {
        let session: String
        let provider: String
        let identityToken: String
    }

    private let overrideEndpoint: URL?
    private let session: URLSession
    private let route: ServiceRoute

    /// 端点读取当前进程已冻结的服务线路。
    private var endpoint: URL {
        overrideEndpoint
            ?? URL(string: route.webBaseURL + "/api/mobile-auth/session")
            ?? URL(string: "https://api.castreader.ai/api/mobile-auth/session")!
    }

    init(
        endpoint: URL? = nil,
        session: URLSession? = nil,
        route: ServiceRoute = ServiceRouting.current
    ) {
        self.overrideEndpoint = endpoint
        self.session = session ?? OwnedAPIURLSession.make(route: route)
        self.route = route
    }

    private var storageKeys: StorageKeys { Self.storageKeys(for: route) }

    static func storageKeys(for route: ServiceRoute) -> StorageKeys {
        StorageKeys(
            session: route.isolatedStorageKey(keychainKey),
            provider: route.isolatedStorageKey(providerKey),
            identityToken: route.isolatedStorageKey(identityTokenKey)
        )
    }

    static func persistedSessionToken(for route: ServiceRoute) -> String? {
        let candidate = KeychainStore.get(storageKeys(for: route).session)?.trimmed
        guard let candidate, isLocallyUsableSessionToken(candidate) else { return nil }
        return candidate
    }

    /// Captures the route's current account boundary for legacy credential
    /// repair. Callers must pass this value back into `exchange`; responses
    /// from an earlier boundary will then be rejected before persistence.
    static func boundaryGeneration(for route: ServiceRoute) -> UInt64 {
        MobileSessionBoundaryClock.shared.snapshot(for: route)
    }

    static func isServerSessionToken(_ token: String) -> Bool {
        token.hasPrefix("cms_")
            && !token.hasPrefix("cms_local_")
            && token.count > 4
            && token.count <= 4_096
    }

    /// The deterministic phone-login bearer exists solely for explicit Debug
    /// UI automation.  Release builds can never accept it, and ordinary Debug
    /// launches do not opt in either. Keeping this narrow exception here lets
    /// end-to-end UI tests exercise account boundaries without weakening the
    /// production requirement for a first-party server session.
    static func isExplicitUITestSessionToken(_ token: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-CastReaderPhoneAuthLocalFallback")
            && token.hasPrefix("cms_local_")
            && token.count > "cms_local_".count
            && token.count <= 4_096
        #else
        return false
        #endif
    }

    private static func isLocallyUsableSessionToken(_ token: String) -> Bool {
        isServerSessionToken(token) || isExplicitUITestSessionToken(token)
    }

    /// Removes the selected route's local credential synchronously and returns
    /// the old server token for a best-effort remote revoke.
    ///
    /// AuthService is MainActor-isolated but sign-out is intentionally a
    /// synchronous UI boundary.  Scheduling the *deletion* in an unstructured
    /// Task used to leave a race in which a very fast account-B login could be
    /// written first and then erased by account A's delayed logout task.  The
    /// local bearer is now detached before the signed-out identity is
    /// published; only the network DELETE remains asynchronous.
    static func detachLocalSession(for route: ServiceRoute) -> String? {
        let keys = storageKeys(for: route)
        let candidate: String? = MobileSessionBoundaryClock.shared.advanceAndPerform(
            for: route
        ) {
            let value = KeychainStore.get(keys.session)?.trimmed
            KeychainStore.delete(keys.session)
            KeychainStore.delete(keys.provider)
            KeychainStore.delete(keys.identityToken)
            return value
        }
        guard let candidate, isLocallyUsableSessionToken(candidate) else { return nil }
        return candidate
    }

    func sessionToken() -> String? {
        guard let token = normalized(KeychainStore.get(storageKeys.session)),
              Self.isLocallyUsableSessionToken(token) else {
            return nil
        }
        return token
    }

    @discardableResult
    func exchange(
        provider: String,
        idToken: String,
        authorizationCode: String? = nil,
        deviceId: String = StableDeviceID.current,
        expectedBoundaryGeneration: UInt64? = nil
    ) async throws -> String {
        guard provider == "google" || provider == "apple" || provider == "email",
              !idToken.trimmed.isEmpty else {
            throw VoiceCloneError.signInRequired
        }
        let boundaryGeneration = expectedBoundaryGeneration
            ?? MobileSessionBoundaryClock.shared.snapshot(for: route)
        guard MobileSessionBoundaryClock.shared.isCurrent(
            boundaryGeneration,
            for: route
        ) else {
            throw VoiceCloneError.sessionUnavailable
        }
        var body: [String: Any] = [
            "provider": provider,
            "idToken": idToken,
            "deviceId": deviceId,
        ]
        // Apple authorization codes are single-use credentials. Send one only
        // to the first-party gateway so the server can exchange it for a
        // refresh token used by `/auth/revoke`; never persist it on device.
        if provider == "apple",
           let code = authorizationCode?.trimmed,
           !code.isEmpty,
           code.count <= 4_096 {
            body["authorizationCode"] = code
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceCloneError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw VoiceCloneError.server(http.statusCode, VoiceCloneResponseParser.serverMessage(from: data))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let token = normalized(payload["token"] as? String),
              Self.isServerSessionToken(token) else {
            throw VoiceCloneError.invalidResponse
        }
        try persistSession(
            token: token,
            provider: provider,
            identityToken: idToken,
            expectedBoundaryGeneration: boundaryGeneration
        )
        return token
    }

    /// 收下由其他登录方式（中国区手机号）直接下发的会话 token。
    ///
    /// 手机号登录没有 idToken 可换，服务端在校验验证码时就把 session 发下来了。
    /// 这类会话无法本地续期，过期后需要用户重新登录（`refreshSession` 因此返回 nil）。
    @discardableResult
    func adoptExternalSession(token: String, provider: String) throws -> String {
        guard let token = normalized(token), Self.isLocallyUsableSessionToken(token),
              provider == "phone" else {
            throw VoiceCloneError.invalidResponse
        }
        let boundaryGeneration = MobileSessionBoundaryClock.shared.snapshot(for: route)
        try persistSession(
            token: token,
            provider: provider,
            identityToken: nil,
            expectedBoundaryGeneration: boundaryGeneration
        )
        return token
    }

    func refreshSession() async -> String? {
        let boundaryGeneration = MobileSessionBoundaryClock.shared.snapshot(for: route)
        guard let provider = normalized(KeychainStore.get(storageKeys.provider)),
              let idToken = normalized(KeychainStore.get(storageKeys.identityToken)) else { return nil }
        return try? await exchange(
            provider: provider,
            idToken: idToken,
            expectedBoundaryGeneration: boundaryGeneration
        )
    }

    func invalidateSession() async {
        let token = Self.detachLocalSession(for: route)
        await revokeDetachedSession(token)
    }

    func rejectSession(_ rejectedToken: String?) async {
        await AuthService.shared.handleRejectedMobileSession(
            rejectedToken: rejectedToken
        )
    }

    /// Revokes exactly the token captured at the local account boundary. This
    /// method deliberately never reads or deletes Keychain state, so it cannot
    /// invalidate a newer login that completed while the request was in flight.
    func revokeDetachedSession(_ token: String?) async {
        guard let token, Self.isServerSessionToken(token) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        _ = try? await session.data(for: request)
    }

    /// A login is not complete until its first-party session is durably
    /// available to protected API clients. Partial Keychain writes are rolled
    /// back, otherwise the UI could publish a signed-in account while every
    /// document/QuickRead request is unauthenticated.
    private func persistSession(
        token: String,
        provider: String,
        identityToken: String?,
        expectedBoundaryGeneration: UInt64
    ) throws {
        let persisted = MobileSessionBoundaryClock.shared.performIfCurrent(
            expectedBoundaryGeneration,
            for: route
        ) { [storageKeys] in
            let wroteSession = KeychainStore.set(token, for: storageKeys.session)
            let wroteProvider = KeychainStore.set(provider, for: storageKeys.provider)
            let wroteIdentity: Bool
            if let identityToken {
                wroteIdentity = KeychainStore.set(
                    identityToken,
                    for: storageKeys.identityToken
                )
            } else {
                KeychainStore.delete(storageKeys.identityToken)
                wroteIdentity = true
            }
            let succeeded = wroteSession && wroteProvider && wroteIdentity
            if !succeeded {
                KeychainStore.delete(storageKeys.session)
                KeychainStore.delete(storageKeys.provider)
                KeychainStore.delete(storageKeys.identityToken)
            }
            return succeeded
        }
        guard persisted == true else {
            throw VoiceCloneError.sessionUnavailable
        }
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
