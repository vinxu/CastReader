//
//  QuickReadService.swift
//  CastReader
//
//  解读后端客户端：extract-plan(SSE) → extract-block(JSON) → compose-block(JSON)。
//  base = 当前进程已冻结的线路：global 走 api.castreader.ai，cn 直连
//  quickread.castreader.cn。
//

import Foundation

/// QuickRead 是自有业务，新版不再读取可把文档内容导向任意域名的客户端远程配置。
/// CN 独立入口是编译期固定合同；供应商切换和容灾只能在所选线路服务端完成。
enum QuickReadEndpoint {
    static let defaultBase = ServiceRoute.globalGateway.quickReadBaseURL
    static let chinaBase = ServiceRoute.chinaGateway.quickReadBaseURL

    static func base() -> String { ComputeRouting.current.quickReadBaseURL }

    /// QuickRead正文 always follows the frozen compute route. When it differs
    /// from the account route, QuickReadService exchanges cms_ at the account
    /// gateway for a target-bound cmc_ ticket in either direction.
    static func preferredComputeBase(
        accountRoute: ServiceRoute = ServiceRouting.current,
        computeRoute: ServiceRoute = ComputeRouting.current
    ) -> String {
        computeRoute.quickReadBaseURL
    }

    @discardableResult
    static func freezeForCurrentProcess() -> String { base() }

    static var planURL: String         { "\(base())/api/quickread/extract-plan" }   // SSE
    static var extractBlockURL: String { "\(base())/api/quickread/extract-block" }  // JSON
    static var composeBlockURL: String { "\(base())/api/quickread/compose-block" }  // JSON
    static var fastBlock0URL: String   { "\(base())/api/quickread/fast-block0" }    // JSON 快道

    /// 保留方法签名供旧启动调用渐进编译；新版的上游切换只在网关服务端完成。
    static func refreshRemoteConfig() async {}

    #if DEBUG
    static func resetProcessSnapshotForTesting() {}
    #endif
}

struct QuickReadComputeTicket: Equatable, Sendable {
    let token: String
    let expiresAt: Date
}

protocol QuickReadComputeSessionProviding: Sendable {
    func ticket(forceRefresh: Bool) async throws -> QuickReadComputeTicket
    func invalidateTicket() async
}

/// Exchanges a route-local cms_ bearer for an in-memory-only ticket targeting
/// the opposite QuickRead ingress. The cmc_ token is audience/target bound by
/// the server; it is never persisted and is never accepted by account, Pro or
/// content APIs.
actor QuickReadComputeSessionStore: QuickReadComputeSessionProviding {
    private struct Envelope: Decodable {
        let code: Int
        let data: Payload
    }

    private struct Payload: Decodable {
        let token: String
        let expiresAt: String
        let audience: String
        let targetRoute: String
    }

    private struct RequestBody: Encodable {
        let audience: String
        let targetRoute: String
    }

    private let accountRoute: ServiceRoute
    private let targetRoute: ServiceRoute
    private let session: URLSession
    private let mobileSessionProvider: MobileSessionProviding
    private let now: @Sendable () -> Date
    private var cached: QuickReadComputeTicket?
    private var cachedSourceCMS: String?

    init(
        accountRoute: ServiceRoute = ServiceRouting.current,
        targetRoute: ServiceRoute = ComputeRouting.current,
        session: URLSession? = nil,
        mobileSessionProvider: MobileSessionProviding = MobileSessionStore.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountRoute = accountRoute
        self.targetRoute = targetRoute
        self.session = session ?? OwnedAPIURLSession.makeExplicitCredentialSession(
            route: accountRoute,
            requestTimeout: 30,
            resourceTimeout: 45
        )
        self.mobileSessionProvider = mobileSessionProvider
        self.now = now
    }

    func ticket(forceRefresh: Bool = false) async throws -> QuickReadComputeTicket {
        guard targetRoute != accountRoute else {
            throw QuickReadError.httpError(422)
        }
        var didRefreshCMS = false
        var cms = await mobileSessionProvider.sessionToken()
        if cachedSourceCMS != cms {
            cached = nil
            cachedSourceCMS = nil
        }
        if cms.map(MobileSessionStore.isServerSessionToken) != true {
            cached = nil
            cachedSourceCMS = nil
            didRefreshCMS = true
            cms = await mobileSessionProvider.refreshSession()
        }
        guard let cms, MobileSessionStore.isServerSessionToken(cms) else {
            throw QuickReadError.httpError(401)
        }
        if !forceRefresh,
           cachedSourceCMS == cms,
           let cached,
           cached.expiresAt.timeIntervalSince(now()) > 60 {
            return cached
        }

        do {
            let exchanged = try await exchange(cms: cms)
            cached = exchanged
            cachedSourceCMS = cms
            return exchanged
        } catch {
            guard Self.isUnauthorized(error), !didRefreshCMS,
                  let refreshed = await mobileSessionProvider.refreshSession(),
                  MobileSessionStore.isServerSessionToken(refreshed) else {
                throw error
            }
            cached = nil
            cachedSourceCMS = nil
            let exchanged = try await exchange(cms: refreshed)
            cached = exchanged
            cachedSourceCMS = refreshed
            return exchanged
        }
    }

    func invalidateTicket() {
        cached = nil
        cachedSourceCMS = nil
    }

    private func exchange(cms: String) async throws -> QuickReadComputeTicket {
        guard let url = URL(
            string: accountRoute.webBaseURL + "/api/mobile-auth/compute-session"
        ) else { throw QuickReadError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(cms)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(audience: "quickread", targetRoute: targetRoute.rawValue)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuickReadError.serverError("invalid compute-session response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuickReadError.httpError(http.statusCode)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.code == 0,
              envelope.data.audience == "quickread",
              envelope.data.targetRoute == targetRoute.rawValue,
              envelope.data.token.hasPrefix("cmc_"),
              envelope.data.token.count > 4,
              envelope.data.token.count <= 4_096,
              let expiry = Self.parseISO8601(envelope.data.expiresAt),
              expiry > now() else {
            throw QuickReadError.serverError("invalid compute-session contract")
        }
        return QuickReadComputeTicket(token: envelope.data.token, expiresAt: expiry)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: value) { return parsed }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case QuickReadError.httpError(let status) = error { return status == 401 }
        return false
    }
}

private enum QuickReadTransportKind: String, Sendable {
    case account
    case computeTicket
}

enum QuickReadError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)
    case serverError(String)
    case decodeError(String)
    case noBlock0
    case computeSessionExpired
    case missingJobTransport

    var errorDescription: String? {
        switch self {
        case .invalidURL: return AppLocalized("无效的解读服务地址")
        case .httpError(let c): return AppLocalized("解读服务错误 (HTTP \(c))")
        case .serverError(let m): return AppLocalized("解读失败：\(m)")
        case .decodeError(let m): return AppLocalized("解读数据解析失败：\(m)")
        case .noBlock0: return AppLocalized("解读未返回首块内容")
        case .computeSessionExpired: return AppLocalized("解读算力凭据已过期")
        case .missingJobTransport: return AppLocalized("解读任务线路状态已丢失，请重新开始解读")
        }
    }
}

enum QuickReadSSEErrorMapper {
    static func map(payload: Data) -> QuickReadError {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return .serverError("unknown")
        }

        let nested = root["error"] as? [String: Any]
        let containers = [root, nested].compactMap { $0 }
        for container in containers {
            for key in ["errorCode", "error_code", "code", "error"] {
                if let code = container[key] as? String,
                   code == "COMPUTE_SESSION_EXPIRED" {
                    return .computeSessionExpired
                }
            }
        }
        let statusKeys = ["code", "status", "statusCode", "http_status", "httpStatus"]
        for container in containers {
            for key in statusKeys {
                if numericStatus(container[key]) == 402 {
                    return .httpError(402)
                }
            }
        }

        let message = containers.compactMap { $0["message"] as? String }.first ?? "unknown"
        return .serverError(message)
    }

    private static func numericStatus(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

actor QuickReadService {
    static let shared = QuickReadService()

    private init() {
        let accountRoute = ServiceRouting.current
        let computeSnapshot = ComputeRouting.currentSnapshot
        self.session = OwnedAPIURLSession.makeExplicitCredentialSession(
            route: accountRoute,
            requestTimeout: 90,
            resourceTimeout: 120
        )
        self.computeSession = OwnedAPIURLSession.makeExplicitCredentialSession(
            route: computeSnapshot.primary,
            requestTimeout: 90,
            resourceTimeout: 120
        )
        self.mobileSessionProvider = MobileSessionStore.shared
        self.computeSessionProvider = QuickReadComputeSessionStore(
            accountRoute: accountRoute,
            targetRoute: computeSnapshot.primary,
            mobileSessionProvider: MobileSessionStore.shared
        )
        self.accountRoute = accountRoute
        self.computeRoute = computeSnapshot.primary
    }

    /// Test-only dependency seam used by transport-boundary contract tests.
    /// Production continues to use `shared` and the default pinned timeouts.
    init(
        session: URLSession,
        mobileSessionProvider: MobileSessionProviding = MobileSessionStore.shared,
        computeSession: URLSession? = nil,
        computeSessionProvider: QuickReadComputeSessionProviding? = nil,
        accountRoute: ServiceRoute = ServiceRouting.current,
        computeRoute: ServiceRoute? = nil
    ) {
        let resolvedComputeRoute = computeRoute ?? accountRoute
        self.session = session
        self.computeSession = computeSession ?? session
        self.mobileSessionProvider = mobileSessionProvider
        self.computeSessionProvider = computeSessionProvider
            ?? QuickReadComputeSessionStore(
                accountRoute: accountRoute,
                targetRoute: resolvedComputeRoute,
                session: session,
                mobileSessionProvider: mobileSessionProvider
            )
        self.accountRoute = accountRoute
        self.computeRoute = resolvedComputeRoute
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session: URLSession
    private let computeSession: URLSession
    private let mobileSessionProvider: MobileSessionProviding
    private let computeSessionProvider: QuickReadComputeSessionProviding
    private let accountRoute: ServiceRoute
    private let computeRoute: ServiceRoute
    private var jobTransports: [String: QuickReadTransportKind] = [:]

    #if DEBUG
    /// Narrow test seam for continuation-only authorization tests. Production
    /// jobs are bound exclusively by extract-plan block0/done events.
    func bindCurrentTransportForTesting(jobID: String) {
        jobTransports[jobID] = preferredTransport
    }
    #endif

    private var preferredTransport: QuickReadTransportKind {
        accountRoute == computeRoute ? .account : .computeTicket
    }

    private func base(for transport: QuickReadTransportKind) -> String {
        switch transport {
        case .account: return accountRoute.quickReadBaseURL
        case .computeTicket: return computeRoute.quickReadBaseURL
        }
    }

    private func url(path: String, transport: QuickReadTransportKind) throws -> URL {
        guard let url = URL(string: base(for: transport) + path) else {
            throw QuickReadError.invalidURL
        }
        return url
    }

    private func networkSession(for transport: QuickReadTransportKind) -> URLSession {
        transport == .computeTicket ? computeSession : session
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[QuickRead] \(message)")
        #endif
    }

    /// 保留设备 id 仅供本地调试输出；两条新网关的 QuickRead 都不发送它。
    /// 额度由网关从 cms_ 的 canonical user + ingress route 推导。
    private static var deviceId: String {
        ProBackendService.deviceId
    }

    private struct AuthHeaderIdentity {
        let userId: String?
        let email: String?
        let isPro: Bool
        let storeKitLocalPro: Bool
        let serverPro: Bool
        let needsEmailSync: Bool
    }

    private func authHeaderIdentity() async -> AuthHeaderIdentity {
        await MainActor.run {
            return AuthHeaderIdentity(
                userId: AuthService.shared.proUserId,
                email: AuthService.shared.normalizedEmail,
                isPro: ProManager.shared.isPro,
                storeKitLocalPro: ProManager.shared.storeKitLocalPro,
                serverPro: ProManager.shared.serverPro,
                needsEmailSync: ProManager.shared.needsEmailSync
            )
        }
    }

    /// 全球/中国网关均只发 cms_ session。网关验证后自行推导 canonical
    /// user 与不可轮换的线路额度主体；客户端输入不得覆盖两者。
    private func applyAuthHeaders(
        _ req: inout URLRequest,
        sessionToken: String,
        transport: QuickReadTransportKind = .account
    ) throws {
        applyBaseHeaders(&req)
        try applyGatewaySessionHeaders(
            &req,
            sessionToken: sessionToken,
            transport: transport
        )
    }

    private func applyBaseHeaders(_ req: inout URLRequest) {
        // 上游 key 只存在网关服务器环境，绝不由新客户端携带。
        req.setValue(Self.localDateString(), forHTTPHeaderField: "x-local-date")
        req.setValue("ios", forHTTPHeaderField: "x-client-platform")
    }

    /// A QuickRead session should spend quota at session start only. Follow-up
    /// block/compose calls are authorized by job_id and intentionally omit
    /// entitlement identity so a conservative server won't count every block as
    /// a new explain.
    private func applyContinuationHeaders(
        _ req: inout URLRequest,
        sessionToken: String,
        transport: QuickReadTransportKind = .account
    ) throws {
        applyBaseHeaders(&req)
        try applyGatewaySessionHeaders(
            &req,
            sessionToken: sessionToken,
            transport: transport
        )
        req.setValue("true", forHTTPHeaderField: "x-quickread-continuation")
    }

    private func applyGatewaySessionHeaders(
        _ req: inout URLRequest,
        sessionToken: String,
        transport: QuickReadTransportKind
    ) throws {
        switch transport {
        case .account:
            guard MobileSessionStore.isServerSessionToken(sessionToken) else {
                throw QuickReadError.httpError(401)
            }
            req.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        case .computeTicket:
            guard sessionToken.hasPrefix("cmc_"),
                  sessionToken.count > 4,
                  sessionToken.count <= 4_096 else {
                throw QuickReadError.httpError(401)
            }
            req.setValue("compute-session", forHTTPHeaderField: "X-Auth-Provider")
        }
        req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
    }

    private func withAuthorization<T>(
        transport: QuickReadTransportKind,
        _ operation: (String) async throws -> T
    ) async throws -> T {
        switch transport {
        case .account:
            return try await withGatewaySessionRefresh(operation)
        case .computeTicket:
            var ticket = try await computeSessionProvider.ticket(forceRefresh: false)
            do {
                return try await operation(ticket.token)
            } catch {
                guard case QuickReadError.computeSessionExpired = error else { throw error }
                // Only the server's exact EXPIRED code may mint once more.
                // Scope/provider/contract failures remain explicit and never
                // reject the account cms_ or move the document to another route.
                await computeSessionProvider.invalidateTicket()
                ticket = try await computeSessionProvider.ticket(forceRefresh: true)
                return try await operation(ticket.token)
            }
        }
    }

    /// Resolve one route-bound server session for an entire QuickRead operation.
    /// A syntactically valid `cms_` token may still have expired server-side, so
    /// the first HTTP 401 performs exactly one same-route refresh and retries the
    /// identical request once. A missing/invalid token spends that single refresh
    /// before touching the network. The refreshed token is passed directly into
    /// request construction, so a stale provider read cannot replay the old token.
    private func withGatewaySessionRefresh<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        var didRefresh = false
        var token = await mobileSessionProvider.sessionToken()

        if token.map(MobileSessionStore.isServerSessionToken) != true {
            didRefresh = true
            token = await mobileSessionProvider.refreshSession()
        }
        guard let token, MobileSessionStore.isServerSessionToken(token) else {
            await mobileSessionProvider.rejectSession(nil)
            throw QuickReadError.httpError(401)
        }

        do {
            return try await operation(token)
        } catch {
            guard Self.isUnauthorized(error) else { throw error }
            guard !didRefresh else {
                await mobileSessionProvider.rejectSession(token)
                throw error
            }
            guard let refreshed = await mobileSessionProvider.refreshSession(),
                  MobileSessionStore.isServerSessionToken(refreshed) else {
                await mobileSessionProvider.rejectSession(token)
                throw error
            }
            do {
                return try await operation(refreshed)
            } catch {
                if Self.isUnauthorized(error) {
                    await mobileSessionProvider.rejectSession(refreshed)
                }
                throw error
            }
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case QuickReadError.httpError(let status) = error {
            return status == 401
        }
        return false
    }

    private static func localDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func debugAuth(_ label: String, identity: AuthHeaderIdentity) {
        debugLog("\(label) AUTH device=\(Self.redact(Self.deviceId)) user=\(Self.redact(identity.userId)) email=\(Self.redactEmail(identity.email)) emailMissing=\(identity.email == nil ? "Y" : "N") pro=\(identity.isPro ? "Y" : "N") storeKitLocal=\(identity.storeKitLocalPro ? "Y" : "N") server=\(identity.serverPro ? "Y" : "N") syncNeeded=\(identity.needsEmailSync ? "Y" : "N")")
    }

    private func debugContinuationAuth(_ label: String, identity: AuthHeaderIdentity) {
        debugLog("\(label) AUTH continuation=Y identityHeaders=N sessionDevice=\(Self.redact(Self.deviceId)) sessionEmail=\(Self.redactEmail(identity.email)) pro=\(identity.isPro ? "Y" : "N")")
    }

    private static func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        if value.count <= 8 { return "\(value.prefix(2))…" }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }

    private static func redactEmail(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        let parts = value.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return redact(value) }
        return "\(parts[0].prefix(2))…@\(parts[1])"
    }

    private static func errorPreview(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        return String(data: data.prefix(2048), encoding: .utf8) ?? "<\(data.count) bytes>"
    }

    private static func errorData(from bytes: URLSession.AsyncBytes, limit: Int = 2048) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {
            return Data("read-error:\(error.localizedDescription)".utf8)
        }
        return data
    }

    /// Compute tickets are refreshed only for the backend's exact expiration
    /// contract. A generic 401, scope mismatch or missing provider is not an
    /// expiration signal and must remain visible to the caller.
    private static func responseError(
        status: Int,
        data: Data,
        transport: QuickReadTransportKind
    ) -> QuickReadError {
        if transport == .computeTicket,
           status == 401,
           structuredErrorCode(in: data) == "COMPUTE_SESSION_EXPIRED" {
            return .computeSessionExpired
        }
        return .httpError(status)
    }

    private static func structuredErrorCode(in data: Data) -> String? {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        func find(in value: Any) -> String? {
            guard let object = value as? [String: Any] else { return nil }
            for key in ["errorCode", "error_code", "code", "error"] {
                if let code = object[key] as? String,
                   code == "COMPUTE_SESSION_EXPIRED" {
                    return code
                }
            }
            for key in ["error", "data", "details"] {
                if let nested = object[key], let code = find(in: nested) {
                    return code
                }
            }
            return nil
        }
        return find(in: root)
    }

    // MARK: - 重试（网络波动 / 后端瞬时错误自愈，指数退避）

    /// 对网络层错误 / 5xx / 429 / 408 / 瞬时 400 / 流式截断自动重试（0.6→1.2→2.4s 退避）。
    /// 让一次抖动不至于打断整条解读链路，用户无需手动 Retry。
    ///
    /// `retryBudget`：重试的墙钟预算。慢失败（worker 跑完 LLM 才断流）每次
    /// 就要几十秒，盲目重试会把一次确定性失败放大成几分钟的静默转圈——
    /// 首次尝试已经烧掉预算时不再重试，让错误尽快到达用户。
    private func withRetry<T>(
        maxAttempts: Int = 3,
        retryBudget: TimeInterval = .infinity,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        let startedAt = Date()
        while true {
            do { return try await operation() }
            catch {
                attempt += 1
                guard attempt < maxAttempts,
                      Date().timeIntervalSince(startedAt) < retryBudget,
                      Self.isRetryable(error) else { throw error }
                let backoff = min(4.0, 0.6 * pow(2.0, Double(attempt - 1)))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }                        // 网络层（超时 / 断连 / DNS）
        if case QuickReadError.httpError(let code) = error {
            return code >= 500 || code == 429 || code == 408 || code == 400   // 服务端临时 / 限流 / 网关瞬时
        }
        if case QuickReadError.decodeError = error { return true }   // 流式截断 / 部分响应
        if case QuickReadError.noBlock0 = error { return true }      // SSE 中途断、没拿到首块
        return false
    }

    /// Freeze the transport before sending正文. A cross-route operation must
    /// acquire its ticket successfully; every failure is fail-closed and is
    /// never converted into an account-route payload request.
    private func preparedTransportForNewPayload() async throws -> QuickReadTransportKind {
        let transport = preferredTransport
        if transport == .computeTicket {
            _ = try await computeSessionProvider.ticket(forceRefresh: false)
        }
        return transport
    }

    // MARK: - extract-plan（SSE）

    /// 通读全文生成大纲 + 首块。onStage/onBlock0 在事件到达时回调；返回 done 载荷。
    @discardableResult
    func extractPlan(_ body: ExtractPlanRequest,
                     onStage: @escaping (String) -> Void,
                     onBlock0: @escaping (PlanBlock0) -> Void) async throws -> PlanDone {
        let payload = try encoder.encode(body)
        let transport = try await preparedTransportForNewPayload()
        debugLog("extract-plan START base=\(base(for: transport)) source=\(body.source_url) scenario=\(body.content_type ?? "general") depth=\(body.depth) lang=\(body.lang ?? "auto") paras=\(body.paragraphs.count) chars=\(body.text.count) bytes=\(payload.count)")
        // 重试整条 SSE（重连重建流）；onBlock0/onStage 在 ExplainViewModel 端幂等（box 覆盖 / 仅更新 UI 文字）。
        let startedAt = Date()
        do {
            return try await performExtractPlan(
                payload: payload,
                transport: transport,
                startedAt: startedAt,
                onStage: onStage,
                onBlock0: onBlock0
            )
        } catch {
            debugLog("extract-plan FAIL elapsed=\(Self.elapsed(startedAt)) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func performExtractPlan(
        payload: Data,
        transport: QuickReadTransportKind,
        startedAt: Date,
        onStage: @escaping (String) -> Void,
        onBlock0: @escaping (PlanBlock0) -> Void
    ) async throws -> PlanDone {
        let endpoint = try url(path: "/api/quickread/extract-plan", transport: transport)
        var observedJobID: String?
        let done = try await withAuthorization(transport: transport) { sessionToken in
            // Plan 是链路里最贵的一跳：一次「慢失败」（worker 跑完 LLM 才断流）
            // 就是 30-120 秒。最多再试一次，且首次已超 60s 就直接把错误交给
            // 用户——活性优先于成功率（产品决策 2026-08-18）。
            try await self.withRetry(maxAttempts: 2, retryBudget: 60) {
                try await self.runExtractPlanOnce(
                    url: endpoint,
                    payload: payload,
                    sessionToken: sessionToken,
                    transport: transport,
                    onStage: onStage,
                    onBlock0: { block in
                        observedJobID = block.job_id
                        // Bind before invoking the external callback. The
                        // callback may immediately launch extract-block, so a
                        // later `done` binding races and could leak the
                        // continuation to the account ingress.
                        self.jobTransports[block.job_id] = transport
                        onBlock0(block)
                    }
                )
            }
        }
        if let jobID = done.job_id ?? observedJobID, !jobID.isEmpty {
            jobTransports[jobID] = transport
        }
        debugLog("extract-plan DONE job=\(done.job_id ?? observedJobID ?? "nil") total=\(done.total_blocks.map(String.init) ?? "nil") model=\(done.model_used ?? "nil") route=\(transport.rawValue) elapsed=\(Self.elapsed(startedAt))")
        return done
    }

    private func runExtractPlanOnce(url: URL, payload: Data,
                                    sessionToken: String,
                                    transport: QuickReadTransportKind,
                                    onStage: @escaping (String) -> Void,
                                    onBlock0: @escaping (PlanBlock0) -> Void) async throws -> PlanDone {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let identity = await authHeaderIdentity()
        try applyAuthHeaders(
            &req,
            sessionToken: sessionToken,
            transport: transport
        )
        debugAuth("extract-plan", identity: identity)
        req.httpBody = payload

        let startedAt = Date()
        let (bytes, response) = try await networkSession(for: transport).bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyData = await Self.errorData(from: bytes)
            debugLog("extract-plan HTTP \(http.statusCode) elapsed=\(Self.elapsed(startedAt)) body=\(Self.errorPreview(bodyData))")
            throw Self.responseError(status: http.statusCode, data: bodyData, transport: transport)
        }

        var eventName = ""
        var dataBuffer = ""
        var done: PlanDone?
        var gotBlock0 = false

        // 注意：URLSession.AsyncBytes.lines 会吞掉 SSE 事件间的空行，
        // 所以不能只靠空行判定边界——遇到下一个 `event:` 或空行就 flush 上一个事件。
        func flush() throws {
            defer { eventName = ""; dataBuffer = "" }
            try dispatch(event: eventName, data: dataBuffer,
                         onStage: onStage,
                         onBlock0: { gotBlock0 = true; onBlock0($0) },
                         onDone: { done = $0 })
        }

        for try await line in bytes.lines {
            if line.isEmpty { try flush(); continue }
            if line.hasPrefix(":") { continue }   // 注释行（如 ": stream-start"）
            if line.hasPrefix("event:") {
                if !eventName.isEmpty || !dataBuffer.isEmpty { try flush() }   // 上一个事件结束
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataBuffer += String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        try flush()   // 末尾事件

        guard gotBlock0 else { throw QuickReadError.noBlock0 }
        return done ?? PlanDone(job_id: nil, total_blocks: nil, model_used: nil, page_summary: nil)
    }

    private func dispatch(event: String, data: String,
                          onStage: (String) -> Void,
                          onBlock0: (PlanBlock0) -> Void,
                          onDone: (PlanDone) -> Void) throws {
        guard !data.isEmpty else { return }
        let payload = Data(data.utf8)
        switch event {
        case "stage":
            if let obj = try? decoder.decode([String: String].self, from: payload), let s = obj["stage"] {
                debugLog("SSE stage=\(s)")
                onStage(s)
            }
        case "block0":
            do {
                let block = try decoder.decode(PlanBlock0.self, from: payload)
                debugLog("SSE block0 job=\(block.job_id) total_hint=\(block.total_blocks) marks=\(block.block_0.events.count) text=\(block.block_0.text.count)")
                onBlock0(block)
            }
            catch { throw QuickReadError.decodeError("block0: \(error)") }
        case "done":
            if let d = try? decoder.decode(PlanDone.self, from: payload) {
                debugLog("SSE done job=\(d.job_id ?? "nil") total=\(d.total_blocks.map(String.init) ?? "nil") model=\(d.model_used ?? "nil")")
                onDone(d)
            }
        case "error":
            let mapped = QuickReadSSEErrorMapper.map(payload: payload)
            debugLog("SSE error=\(mapped.localizedDescription)")
            throw mapped
        default:
            break   // 未知事件忽略
        }
    }

    // MARK: - extract-block / compose-block（JSON）

    func extractBlock(jobId: String, blockIdx: Int) async throws -> QuickreadSection {
        guard let transport = jobTransports[jobId] else {
            throw QuickReadError.missingJobTransport
        }
        let body = ExtractBlockRequest(job_id: jobId, block_idx: blockIdx)
        return try await postSection(
            path: "/api/quickread/extract-block",
            body: body,
            label: "extract-block[\(blockIdx)]",
            transport: transport
        )
    }

    func composeBlock(jobId: String, blockIdx: Int,
                      timestamps: [ComposeTimestamp], duration: Double) async throws -> QuickreadSection {
        guard let transport = jobTransports[jobId] else {
            throw QuickReadError.missingJobTransport
        }
        let body = ComposeBlockRequest(job_id: jobId, block_idx: blockIdx,
                                       timestamps: timestamps, duration: duration)
        return try await postSection(
            path: "/api/quickread/compose-block",
            body: body,
            label: "compose-block[\(blockIdx)] ts=\(timestamps.count) dur=\(String(format: "%.1f", duration))",
            transport: transport
        )
    }

    // MARK: - 快道（fast-block0）

    /// 快道：标题 + 开头 N 段 → 一次 LLM 直出 block_0{narration, marks}（marks 无 at），跳过读整篇 + compose。
    /// 失败即抛出、**不重试**（快道的意义是快；失败由竞速兜底——质道 block_0 自然顶上）。超时 8s。
    /// 返回精简 section（text=narration、events=过滤后的 marks）。
    func fastBlock0(title: String, openingParas: [String], lang: String?,
                    depth: String, prevSummary: String?, contentType: String?) async throws -> QuickreadSection {
        let body = FastBlock0Request(title: title,
                                     openingParas: openingParas.map { FastBlock0OpeningPara(text: $0) },
                                     lang: lang, depth: depth, prev_summary: prevSummary, content_type: contentType)
        let startedAt = Date()
        debugLog("fast-block0 START scenario=\(contentType ?? "general") depth=\(depth) lang=\(lang ?? "auto") opening=\(openingParas.count) chars=\(openingParas.reduce(0) { $0 + $1.count })")
        let payload = try encoder.encode(body)
        let transport = try await preparedTransportForNewPayload()
        return try await performFastBlock0(
            payload: payload,
            transport: transport,
            startedAt: startedAt
        )
    }

    private func performFastBlock0(
        payload: Data,
        transport: QuickReadTransportKind,
        startedAt: Date
    ) async throws -> QuickreadSection {
        let endpoint = try url(path: "/api/quickread/fast-block0", transport: transport)
        return try await withAuthorization(transport: transport) { sessionToken in
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let identity = await self.authHeaderIdentity()
            try self.applyAuthHeaders(
                &req,
                sessionToken: sessionToken,
                transport: transport
            )
            self.debugAuth("fast-block0", identity: identity)
            req.httpBody = payload
            req.timeoutInterval = 8   // 快道超时即放弃，走质道

            let (data, response) = try await self.networkSession(for: transport).data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.debugLog("fast-block0 HTTP \(http.statusCode) elapsed=\(Self.elapsed(startedAt)) body=\(Self.errorPreview(data))")
                throw Self.responseError(status: http.statusCode, data: data, transport: transport)
            }
            let resp = try self.decoder.decode(FastBlock0Response.self, from: data)
            guard let b0 = resp.block_0,
                  !b0.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.debugLog("fast-block0 noBlock0 elapsed=\(Self.elapsed(startedAt))")
                throw QuickReadError.noBlock0
            }
            // marks 精简形态 → QuickreadEvent：非空 text 保留；at 留空（端侧均匀分布，见 ensureTiming）。
            // 场景化后端会返回 wave/star/strike/weight/role。旧白名单只保留 4 种，导致快道首块可见 mark 被压低。
            let supported: Set<String> = ["highlight", "underline", "wave", "strike", "circle", "star", "number"]
            let events = (b0.marks ?? [])
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map {
                    let style = supported.contains($0.style) ? $0.style : "underline"
                    return QuickreadEvent(at: nil, action: style, text: $0.text, n: $0.n,
                                          role: $0.role, weight: $0.weight, note: $0.note)
                }
            self.debugLog("fast-block0 DONE marks_raw=\(b0.marks?.count ?? 0) marks_kept=\(events.count) text=\(b0.narration.count) elapsed=\(Self.elapsed(startedAt))")
            return QuickreadSection(id: "fast-0", text: b0.narration, style: "explain",
                                    cinematic: QuickreadCinematic(events: events))
        }
    }

    private func postSection<Body: Encodable>(
        path: String,
        body: Body,
        label: String,
        transport: QuickReadTransportKind
    ) async throws -> QuickreadSection {
        let endpoint = try url(path: path, transport: transport)
        let payload = try encoder.encode(body)
        debugLog("\(label) START bytes=\(payload.count)")
        let startedAt = Date()
        return try await withAuthorization(transport: transport) { sessionToken in
            try await self.withRetry {
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let identity = await self.authHeaderIdentity()
                try self.applyContinuationHeaders(
                    &req,
                    sessionToken: sessionToken,
                    transport: transport
                )
                self.debugContinuationAuth(label, identity: identity)
                req.httpBody = payload
                let (data, response) = try await self.networkSession(for: transport).data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self.debugLog("\(label) HTTP \(http.statusCode) elapsed=\(Self.elapsed(startedAt)) body=\(Self.errorPreview(data))")
                    throw Self.responseError(status: http.statusCode, data: data, transport: transport)
                }
                do {
                    let section = try self.decoder.decode(QuickreadSectionResponse.self, from: data).section
                    self.debugLog("\(label) DONE marks=\(section.events.count) text=\(section.text.count) elapsed=\(Self.elapsed(startedAt))")
                    return section
                } catch {
                    self.debugLog("\(label) DECODE_FAIL elapsed=\(Self.elapsed(startedAt)) error=\(error)")
                    throw QuickReadError.decodeError("\(error)")
                }
            }
        }
    }

    private static func elapsed(_ startedAt: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }
}
