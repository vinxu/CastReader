//
//  PhoneAuthService.swift
//  CastReader
//
//  中国区手机号短信登录。
//
//  只在 `AppRegion.current == .cn` 时对用户可见；其他地区的登录路径
//  （Google / Apple）完全不经过这里。
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
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func post(url: URL, body: [String: Any], bearer: String?) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
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
}

@MainActor
final class PhoneAuthService: ObservableObject {
    static let shared = PhoneAuthService()

    private let transport: PhoneAuthTransport

    init(transport: PhoneAuthTransport = URLSessionPhoneAuthTransport()) {
        self.transport = transport
    }

    /// 中国区之外不开放手机号登录。
    var isAvailable: Bool { AppRegion.current == .cn }

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
    /// 存在的理由：境内后端（`castreader.cn`）备案未完成、短信通道也未接通，
    /// 但中国区版本必须能被完整走查——引导、登录、Pro 态、付费页缺一不可。
    /// 没有这条兜底，整个中国区就只能停在登录页。
    ///
    /// 生效条件极窄：**仅中国区** + **仅预设码** + **仅在后端确实不可达时**。
    /// 后端一旦可用，真实流程优先，这条路径不会被触发。
    enum LocalFallback {
        /// 预设验证码。与后端 `PHONE_AUTH_DEV_CODE` 保持一致，便于两边同一套操作习惯。
        static let presetCode = "888888"

        /// 是否允许本地直通。
        ///
        /// 2026-08-08 起 Release 构建**一律关闭**：境内后端
        /// （`api.castreader.cn`）已上线，真实短信通道也已打通，
        /// 这条兜底已经没有存在理由。留着反而是个洞 —— 攻击者只要断网，
        /// 输入预设码就能以任意手机号进入本地态。
        ///
        /// Debug 构建保留，便于模拟器上不依赖真实短信走查完整引导流程。
        /// 应用商店审核员用的是后端的 `PHONE_AUTH_REVIEW_PHONES` 白名单，
        /// 不走这条路径。
        static var isEnabled: Bool {
            #if DEBUG
            return AppRegion.current == .cn
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
                // 服务端明确拒绝（号码非法、频控）时如实报错，不要用兜底掩盖。
                if Self.isDefinitiveRejection(error) { throw error }
                throw PhoneAuthError.network
            }

            let payload = Self.dataObject(from: data)
            return PhoneCodeChallenge(
                ttlSeconds: payload?["ttl"] as? Int ?? PhoneCodeChallenge.fallback.ttlSeconds,
                resendAfterSeconds: payload?["resendAfter"] as? Int
                    ?? PhoneCodeChallenge.fallback.resendAfterSeconds
            )
        } catch let error as PhoneAuthError {
            if Self.isDefinitiveRejection(error) { throw error }
            // 后端不可达：允许用户用预设码继续。
            guard LocalFallback.isEnabled else { throw error }
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
                if Self.isDefinitiveRejection(error) { throw error }
                throw PhoneAuthError.network
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
            if Self.isDefinitiveRejection(error) { throw error }
            // 后端不可达：只有预设码才放行，普通验证码仍然报网络错误，
            // 避免让用户以为「随便输都能进」。
            guard LocalFallback.matches(code) else { throw error }
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

    /// 提交注销申请。后端按冷静期删除个人信息；客户端在本地立即登出。
    func deleteAccount(sessionToken: String) async throws {
        // 本地直通签发的会话没有服务端记录，直接本地登出即可。
        if sessionToken.hasPrefix("cms_local_") { return }

        let (status, data) = try await transport.post(
            url: try endpoint("/api/mobile-auth/account/delete"),
            body: ["deviceId": StableDeviceID.current],
            bearer: sessionToken
        )
        guard 200..<300 ~= status else {
            throw Self.decodeError(status: status, data: data)
        }
    }

    // MARK: - 解析

    /// 服务端给出的**明确业务拒绝**：这类错误必须如实呈现，不能被本地兜底掩盖，
    /// 否则用户会以为随便一个号码/验证码都能登录。
    nonisolated static func isDefinitiveRejection(_ error: PhoneAuthError) -> Bool {
        switch error {
        case .invalidPhone, .invalidCode, .codeExpired, .tooManyRequests, .notAvailableInRegion:
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
