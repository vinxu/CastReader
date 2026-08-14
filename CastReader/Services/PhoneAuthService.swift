//
//  PhoneAuthService.swift
//  CastReader
//
//  中国区手机号短信登录。
//
//  只由 `AppRegion.current == .cn` 决定是否对用户可见；服务线路只选择入口域名。
//  新版 globalGateway 与 chinaGateway 的 mobile-auth 端点共享 canonical 账号库。
//
//  隐私边界：手机号只在请求体里出现，**绝不**写日志、绝不进埋点
//  （`ProductAnalytics` 的禁用字段已包含 phone/smsCode 等，出现即抛错）。
//

import Foundation

/// 便于单测替换的最小网络抽象。
protocol PhoneAuthTransport: Sendable {
    func post(url: URL, body: [String: Any], bearer: String?) async throws -> (Int, Data)
}

struct URLSessionPhoneAuthTransport: PhoneAuthTransport {
    static let defaultTimeout: TimeInterval = 12
    static let verificationTimeout: TimeInterval = 30

    let session: URLSession

    init(
        session: URLSession? = nil,
        route: ServiceRoute = ServiceRouting.current
    ) {
        self.session = session ?? OwnedAPIURLSession.make(route: route)
    }

    func post(url: URL, body: [String: Any], bearer: String?) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeoutInterval(for: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PhoneAuthError.network
            }
            return (http.statusCode, data)
        } catch let error as PhoneAuthError {
            throw error
        } catch {
            throw PhoneAuthError.network
        }
    }

    /// Verifying an SMS code may create/link the canonical identity before the
    /// gateway can return its first `cms_` session. Give that one operation
    /// enough time to complete; send/resend and account deletion remain tightly
    /// bounded so an unavailable endpoint still fails quickly.
    nonisolated static func timeoutInterval(for url: URL) -> TimeInterval {
        url.path == "/api/mobile-auth/sms/verify"
            ? verificationTimeout
            : defaultTimeout
    }
}

@MainActor
final class PhoneAuthService: ObservableObject {
    static let shared = PhoneAuthService()

    private let transport: PhoneAuthTransport
    private let localFallbackPolicy: LocalFallbackPolicy

    /// `localFallbackEnabledForTesting` 只供单元测试注入“后端断网时允许兜底”。
    /// 真实 App 进程只认显式 UI 测试启动参数，普通 Debug 真机不会启用。
    init(
        transport: PhoneAuthTransport = URLSessionPhoneAuthTransport(),
        localFallbackEnabledForTesting: Bool? = nil
    ) {
        self.transport = transport
        if let localFallbackEnabledForTesting {
            self.localFallbackPolicy = localFallbackEnabledForTesting
                ? .backendUnavailable
                : .disabled
        } else {
            self.localFallbackPolicy = LocalFallback.isForcedForUITests
                ? .forced
                : .disabled
        }
    }

    private enum LocalFallbackPolicy: Equatable {
        case disabled
        /// 单元测试可注入：只在传输层确实不可达时兜底。
        case backendUnavailable
        /// UI 自动化显式启用：跳过真实短信端点，保证测试确定性。
        case forced
    }

    /// 手机号是中国产品能力；网络线路只决定同一账号服务从哪个入口进入。
    var isAvailable: Bool {
        AppRegion.current == .cn
    }

    private var baseURL: String { Constants.API.webURL }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw PhoneAuthError.server(status: -1, message: nil)
        }
        return url
    }

    // MARK: - 本地预设直通

    /// 后端不可达时，用预设验证码在本地完成登录。
    ///
    /// 存在的理由：开发与 UI 自动化需要在不消耗真实短信、不依赖外部网络时
    /// 完整走查中国区引导、登录、Pro 态与付费页。
    ///
    /// 生效条件极窄：**仅中国区** + **仅预设码** + **仅在后端确实不可达时**。
    /// 后端一旦可用，真实流程优先，这条路径不会被触发。
    enum LocalFallback {
        /// 预设验证码。与后端 `PHONE_AUTH_DEV_CODE` 保持一致，便于两边同一套操作习惯。
        static let presetCode = "888888"

        /// 是否允许本地直通。
        ///
        /// Release 构建**一律关闭**。这条兜底只用于尚未部署完整中国线路时的
        /// Debug/模拟器界面走查；进入任何 TestFlight/App Store 验收包都会失效。
        /// 把它带进生产会形成安全洞 —— 攻击者只要断网，
        /// 输入预设码就能以任意手机号进入本地态。
        ///
        /// Debug 构建也不默认开启。只有 UI 自动化显式传入
        /// `-CastReaderPhoneAuthLocalFallback` 才会生效；这样 Debug 真机
        /// 能看到真实的网关/短信错误，不会被 888888 掩盖。
        /// 应用商店审核员用的是后端的 `PHONE_AUTH_REVIEW_PHONES` 白名单，
        /// 不走这条路径。
        static var isEnabled: Bool {
            #if DEBUG
            let isDebugBuild = true
            #else
            let isDebugBuild = false
            #endif
            return isEnabled(
                arguments: ProcessInfo.processInfo.arguments,
                region: AppRegion.current,
                isDebugBuild: isDebugBuild
            )
        }

        /// 纯策略入口，便于单测覆盖 Debug / Release、中国/全球与
        /// 启动参数组合，不依赖当前 XCTest 进程的真实参数。
        nonisolated static func isEnabled(
            arguments: [String],
            region: AppRegion,
            isDebugBuild: Bool
        ) -> Bool {
            isDebugBuild
                && region == .cn
                && arguments.contains("-CastReaderPhoneAuthLocalFallback")
        }

        /// UI 自动化显式要求本地链路时跳过真实短信端点，避免频控、运营商延迟
        /// 或审核白名单让测试变得不确定。该参数只存在于 Debug 构建。
        static var isForcedForUITests: Bool {
            isEnabled
        }

        /// Deterministic UI-test hook for the exact recovery path where SMS
        /// send fails but the user already owns a valid code. It is compiled
        /// out of Release and never changes ordinary Debug launches.
        static var isForcedSendFailureForUITests: Bool {
            #if DEBUG
            return AppRegion.current == .cn
                && ProcessInfo.processInfo.arguments.contains(
                    "-CastReaderPhoneAuthForceSendFailure"
                )
            #else
            return false
            #endif
        }

        static func matches(_ code: String) -> Bool {
            isEnabled && code == presetCode
        }

        /// 为该号码生成稳定的本地用户 id：同一号码每次登录拿到同一个 id，
        /// 这样本地历史、Pro 态、埋点归因在多次登录之间是连续的。
        static func localUserId(for localNumber: String) -> String {
            "cn_local_\(localNumber)"
        }

        static func localSessionToken(for localNumber: String) -> String {
            // 沿用 cms_ 前缀，让下游会话判断逻辑无需分叉。
            "cms_local_\(localNumber)"
        }
    }

    // MARK: - 发送验证码

    @discardableResult
    func sendCode(phone rawPhone: String, scene: String = "sign_in") async throws -> PhoneCodeChallenge {
        guard isAvailable else { throw PhoneAuthError.notAvailableInRegion }
        guard let local = ChinaPhoneNumber.normalize(rawPhone) else {
            throw PhoneAuthError.invalidPhone
        }

        if LocalFallback.isForcedSendFailureForUITests {
            throw PhoneAuthError.network
        }

        if localFallbackPolicy == .forced {
            return PhoneCodeChallenge(
                ttlSeconds: PhoneCodeChallenge.fallback.ttlSeconds,
                resendAfterSeconds: 0,
                usedLocalFallback: true
            )
        }

        do {
            let (status, data) = try await transport.post(
                url: try endpoint("/api/mobile-auth/sms/send"),
                body: [
                    "phone": ChinaPhoneNumber.e164(local),
                    "scene": scene,
                    "deviceId": StableDeviceID.current,
                ],
                bearer: nil
            )

            guard 200..<300 ~= status else {
                let error = Self.decodeError(status: status, data: data)
                // HTTP 响应已证明后端可达。号码、频控、sms_unavailable
                // 与其他服务端错误都必须原样上抛，不得伪装成断网。
                throw error
            }

            let payload = Self.dataObject(from: data)
            return PhoneCodeChallenge(
                ttlSeconds: payload?["ttl"] as? Int ?? PhoneCodeChallenge.fallback.ttlSeconds,
                resendAfterSeconds: payload?["resendAfter"] as? Int
                    ?? PhoneCodeChallenge.fallback.resendAfterSeconds
            )
        } catch let error as PhoneAuthError {
            // 只有单元测试显式注入时，才可在传输层不可达后兜底。
            // 普通 Debug 真机与所有 HTTP 服务端错误都如实上抛。
            guard localFallbackPolicy == .backendUnavailable,
                  error == .network else { throw error }
            return PhoneCodeChallenge(
                ttlSeconds: PhoneCodeChallenge.fallback.ttlSeconds,
                resendAfterSeconds: 0,
                usedLocalFallback: true
            )
        }
    }

    // MARK: - 校验并登录

    func verify(phone rawPhone: String, code rawCode: String) async throws -> PhoneSignInResult {
        guard isAvailable else { throw PhoneAuthError.notAvailableInRegion }
        guard let local = ChinaPhoneNumber.normalize(rawPhone) else {
            throw PhoneAuthError.invalidPhone
        }
        let code = PhoneVerificationCode.sanitize(rawCode)
        guard PhoneVerificationCode.isComplete(code) else {
            throw PhoneAuthError.invalidCode
        }

        if localFallbackPolicy == .forced, code == LocalFallback.presetCode {
            return PhoneSignInResult(
                sessionToken: LocalFallback.localSessionToken(for: local),
                userId: LocalFallback.localUserId(for: local),
                isNewUser: false,
                displayName: ChinaPhoneNumber.masked(rawPhone),
                usedLocalFallback: true
            )
        }

        do {
            let (status, data) = try await transport.post(
                url: try endpoint("/api/mobile-auth/sms/verify"),
                body: [
                    "phone": ChinaPhoneNumber.e164(local),
                    "code": code,
                    "deviceId": StableDeviceID.current,
                ],
                bearer: nil
            )

            guard 200..<300 ~= status else {
                let error = Self.decodeError(status: status, data: data)
                throw error
            }

            guard let payload = Self.dataObject(from: data),
                  let token = (payload["sessionToken"] as? String)?.trimmed, !token.isEmpty,
                  let userId = (payload["userId"] as? String)?.trimmed, !userId.isEmpty else {
                throw PhoneAuthError.server(status: status, message: nil)
            }

            return PhoneSignInResult(
                sessionToken: token,
                userId: userId,
                isNewUser: payload["isNewUser"] as? Bool ?? false,
                displayName: (payload["displayName"] as? String)?.trimmed
            )
        } catch let error as PhoneAuthError {
            // 只有测试注入 + 传输层不可达 + 预设码才放行。
            guard localFallbackPolicy == .backendUnavailable,
                  error == .network,
                  code == LocalFallback.presetCode else { throw error }
            return PhoneSignInResult(
                sessionToken: LocalFallback.localSessionToken(for: local),
                userId: LocalFallback.localUserId(for: local),
                isNewUser: false,
                displayName: ChinaPhoneNumber.masked(rawPhone),
                usedLocalFallback: true
            )
        }
    }

    // MARK: - 账号注销

    /// 提交 provider-neutral 注销申请。后端返回实际冷静期，以及旧 Apple
    /// 账号是否需要用户手动撤销授权；客户端不得用硬编码文案覆盖该事实。
    func deleteAccount(sessionToken: String) async throws -> AccountDeletionReceipt {
        // 本地直通签发的会话没有服务端记录，直接本地登出即可。
        if sessionToken.hasPrefix("cms_local_") { return .localOnly }

        let (status, data) = try await transport.post(
            url: try endpoint("/api/mobile-auth/account/delete"),
            body: ["deviceId": StableDeviceID.current],
            bearer: sessionToken
        )
        guard 200..<300 ~= status else {
            throw Self.decodeError(status: status, data: data)
        }
        return Self.decodeAccountDeletionReceipt(data: data)
    }

    nonisolated static func decodeAccountDeletionReceipt(
        data: Data
    ) -> AccountDeletionReceipt {
        let payload = dataObject(from: data) ?? [:]
        let status = ((payload["status"] as? String)?.trimmed).flatMap {
            $0.isEmpty ? nil : String($0.prefix(80))
        } ?? "accepted"
        let rawGraceDays: Int
        if let value = payload["graceDays"] as? NSNumber {
            rawGraceDays = value.intValue
        } else if let value = payload["grace_days"] as? NSNumber {
            rawGraceDays = value.intValue
        } else if let value = payload["graceDays"] as? String {
            rawGraceDays = Int(value) ?? 0
        } else if let value = payload["grace_days"] as? String {
            rawGraceDays = Int(value) ?? 0
        } else {
            rawGraceDays = 0
        }
        let manual = boolean(
            payload["manualAppleRevocationRequired"]
                ?? payload["manual_apple_revocation_required"]
        )
        return AccountDeletionReceipt(
            status: status,
            graceDays: min(max(rawGraceDays, 0), 3_650),
            manualAppleRevocationRequired: manual
        )
    }

    private nonisolated static func boolean(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return ["true", "1", "yes"].contains(value.trimmed.lowercased())
        }
        return false
    }

    // MARK: - 解析

    /// 服务端给出的**明确业务拒绝**：这类错误必须如实呈现，不能被本地兜底掩盖，
    /// 否则用户会以为随便一个号码/验证码都能登录。
    nonisolated static func isDefinitiveRejection(_ error: PhoneAuthError) -> Bool {
        switch error {
        case .invalidPhone, .invalidCode, .codeExpired, .tooManyRequests,
             .smsUnavailable, .notAvailableInRegion:
            return true
        case .network, .server:
            return false
        }
    }

    /// 纯解析，不碰任何主线程状态，因此显式脱离 actor 隔离。
    nonisolated static func dataObject(from data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root["data"] as? [String: Any] ?? root
    }

    nonisolated static func decodeError(status: Int, data: Data) -> PhoneAuthError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (root?["code"] as? String) ?? (root?["error"] as? String)
        let message = (root?["message"] as? String)?.trimmed

        // 频控要把服务端给的等待秒数带出来，界面才能显示准确倒计时。
        if status == 429 || code == "rate_limited" {
            let payload = root?["data"] as? [String: Any]
            let retryAfter = payload?["retryAfter"] as? Int
                ?? root?["retryAfter"] as? Int
                ?? 0
            return .tooManyRequests(retryAfter: retryAfter)
        }
        return PhoneAuthError.from(status: status, code: code, message: message)
    }
}
