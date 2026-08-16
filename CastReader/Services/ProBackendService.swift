//
//  ProBackendService.swift
//  CastReader
//
//  Build-39 原生账号/Pro 后端。cms_ session 是唯一账号权威；客户端不再把
//  user_id/email 送到旧公开接口。服务端只从 cms_ 的 canonical user 和 ingress
//  route 派生额度主体；客户端 device id 仅作为向后兼容字段，不能改变额度归属。
//

import Foundation

struct ProAccountDTO: Decodable, Equatable {
    let name: String?
    let email: String?
    let image: String?
}

struct ProStatusDTO: Decodable, Equatable {
    let pro: Bool
    let plan: String?
    let account: ProAccountDTO?
    let freeRemaining: Int?
    let freeMax: Int?
    let listenSeconds: Int?
    let listenLimit: Int?
    let listenRemaining: Int?
    let resolvedUserId: String?
    /// 额度策略（two_tier_v1 实验开关，服务端按美区新用户下发）。
    /// two_tier 语义下 listenRemaining / freeRemaining 为总剩余（赠额+月度）。
    let quotaPolicy: String?
    /// 首装赠额层剩余（秒 / 次）。仅 two_tier 下发。
    let grantListenRemaining: Int?
    let grantExplainRemaining: Int?

    init(
        pro: Bool,
        plan: String?,
        account: ProAccountDTO?,
        freeRemaining: Int?,
        freeMax: Int?,
        listenSeconds: Int?,
        listenLimit: Int?,
        listenRemaining: Int?,
        resolvedUserId: String? = nil,
        quotaPolicy: String? = nil,
        grantListenRemaining: Int? = nil,
        grantExplainRemaining: Int? = nil
    ) {
        self.pro = pro
        self.plan = plan
        self.account = account
        self.freeRemaining = freeRemaining
        self.freeMax = freeMax
        self.listenSeconds = listenSeconds
        self.listenLimit = listenLimit
        self.listenRemaining = listenRemaining
        self.resolvedUserId = resolvedUserId
        self.quotaPolicy = quotaPolicy
        self.grantListenRemaining = grantListenRemaining
        self.grantExplainRemaining = grantExplainRemaining
    }
}

private struct ProStatusEnvelopeDTO: Decodable {
    let data: ProStatusDTO
}

extension ProStatusDTO {
    static func decodeServerResponse(from data: Data) throws -> ProStatusDTO {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(ProStatusDTO.self, from: data) {
            return direct
        }
        return try decoder.decode(ProStatusEnvelopeDTO.self, from: data).data
    }
}

enum ProStatusFetchOutcome: Equatable {
    case success(ProStatusDTO)
    case unauthorized(rejectedToken: String?)
    case unavailable
}

actor ProBackendService {
    static let shared = ProBackendService()
    private let session: URLSession

    private init(session: URLSession = OwnedAPIURLSession.shared) {
        self.session = session
    }

    /// 稳定设备 id（复用 visitor id）。
    static var deviceId: String {
        StableDeviceID.current
    }

    /// 查询 Pro/额度。账号只由 cms_ session 解析；query 不包含 user_id/email，
    /// 服务端也不会把可轮换的 device_id 当作 v2 额度主键。
    func fetchStatus() async -> ProStatusFetchOutcome {
        guard var comps = URLComponents(string: Constants.API.mobileProStatusV2) else {
            return .unavailable
        }
        comps.queryItems = [
            URLQueryItem(name: "device_id", value: Self.deviceId),
            URLQueryItem(name: "local_date", value: Self.localDay())
        ]
        guard let url = comps.url else { return .unavailable }
        return await performStatus(url: url, canRefreshSession: true)
    }

    private func performStatus(
        url: URL,
        canRefreshSession: Bool
    ) async -> ProStatusFetchOutcome {
        var token = await MobileSessionStore.shared.sessionToken()
        if token == nil, canRefreshSession {
            token = await MobileSessionStore.shared.refreshSession()
        }
        guard let token, !token.isEmpty else {
            Self.debugLog("status BLOCK mobile-session-missing")
            return .unauthorized(rejectedToken: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        Self.debugLog("status-v2 START device=\(Self.redact(Self.deviceId))")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            if http.statusCode == 401 {
                if canRefreshSession,
                   await MobileSessionStore.shared.refreshSession() != nil {
                    return await performStatus(url: url, canRefreshSession: false)
                }
                return .unauthorized(rejectedToken: token)
            }
            guard (200..<300).contains(http.statusCode) else {
                Self.debugLog("status HTTP \(http.statusCode) body=\(Self.preview(data))")
                return .unavailable
            }
            let status = try ProStatusDTO.decodeServerResponse(from: data)
            Self.debugLog("status DONE pro=\(status.pro ? "Y" : "N") plan=\(status.plan ?? "nil") free=\(status.freeRemaining.map(String.init) ?? "nil") listen=\(status.listenRemaining.map(String.init) ?? "nil")")
            return .success(status)
        } catch {
            Self.debugLog("status FAIL error=\(error.localizedDescription)")
            return .unavailable
        }
    }

    /// Upload an Apple-signed StoreKit 2 transaction under the authenticated
    /// first-party mobile session. The server verifies Apple's JWS chain and
    /// binds the entitlement to the session's email-backed account.
    func verifyAppleTransaction(_ signedTransaction: String) async -> Bool {
        guard !signedTransaction.isEmpty,
              let url = URL(string: Constants.API.proVerifyApple) else { return false }
        return await performAppleVerification(
            signedTransaction: signedTransaction,
            url: url,
            canRefreshSession: true
        )
    }

    private func performAppleVerification(
        signedTransaction: String,
        url: URL,
        canRefreshSession: Bool
    ) async -> Bool {
        var token = await MobileSessionStore.shared.sessionToken()
        if token == nil, canRefreshSession {
            token = await MobileSessionStore.shared.refreshSession()
        }
        guard let token, !token.isEmpty else {
            Self.debugLog("verify-apple SKIP mobile-session-missing")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "signed_transaction": signedTransaction,
            "device_id": Self.deviceId,
            "local_date": Self.localDay()
        ])
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 401, canRefreshSession,
               await MobileSessionStore.shared.refreshSession() != nil {
                return await performAppleVerification(
                    signedTransaction: signedTransaction,
                    url: url,
                    canRefreshSession: false
                )
            }
            if http.statusCode == 401 {
                await MobileSessionStore.shared.rejectSession(token)
                return false
            }
            guard (200..<300).contains(http.statusCode) else {
                Self.debugLog("verify-apple HTTP \(http.statusCode) body=\(Self.preview(data))")
                return false
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["data"] as? [String: Any],
                  payload["pro"] as? Bool == true else {
                Self.debugLog("verify-apple invalid response body=\(Self.preview(data))")
                return false
            }
            Self.debugLog("verify-apple DONE pro=Y")
            return true
        } catch {
            Self.debugLog("verify-apple FAIL error=\(error.localizedDescription)")
            return false
        }
    }

    /// 上报朗读秒数（增量）。cms_ 过期时不回退旧公开 user_id 合同。
    func trackListen(seconds: Int) async {
        guard seconds > 0,
              let url = URL(string: Constants.API.mobileProListenTrackV2) else { return }
        await performListenTrack(seconds: seconds, url: url, canRefreshSession: true)
    }

    private func performListenTrack(
        seconds: Int,
        url: URL,
        canRefreshSession: Bool
    ) async {
        var token = await MobileSessionStore.shared.sessionToken()
        if token == nil, canRefreshSession {
            token = await MobileSessionStore.shared.refreshSession()
        }
        guard let token, !token.isEmpty else {
            Self.debugLog("track-v2 BLOCK mobile-session-missing")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        let body: [String: Any] = [
            "device_id": Self.deviceId,
            "seconds": seconds,
            "local_date": Self.localDay()
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Self.debugLog("track-v2 START seconds=\(seconds) device=\(Self.redact(Self.deviceId))")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401, canRefreshSession,
               await MobileSessionStore.shared.refreshSession() != nil {
                await performListenTrack(
                    seconds: seconds,
                    url: url,
                    canRefreshSession: false
                )
                return
            }
            if http.statusCode == 401 {
                await MobileSessionStore.shared.rejectSession(token)
                return
            }
            if !(200..<300).contains(http.statusCode) {
                Self.debugLog("track HTTP \(http.statusCode) body=\(Self.preview(data))")
            }
        } catch {
            Self.debugLog("track FAIL error=\(error.localizedDescription)")
        }
    }

    static func localDay() -> String {
        let f = DateFormatter()
        f.calendar = .current; f.locale = .current; f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[ProBackend] \(message)")
        #endif
    }

    private static func redact(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "nil" }
        if value.count <= 8 { return "\(value.prefix(2))…" }
        return "\(value.prefix(4))…\(value.suffix(4))"
    }

    private static func redactEmail(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "nil"
        }
        let parts = value.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return redact(value) }
        return "\(parts[0].prefix(2))…@\(parts[1])"
    }

    private static func preview(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        return String(data: data.prefix(1024), encoding: .utf8) ?? "<\(data.count) bytes>"
    }
}
