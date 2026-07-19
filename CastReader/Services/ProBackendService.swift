//
//  ProBackendService.swift
//  CastReader
//
//  账号/Pro 后端（readout-web，公开端点）。device_id 即可查询；登录后附带 user_id。
//  /api/pro/status（GET）、/api/pro/listen-track（POST）。
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

actor ProBackendService {
    static let shared = ProBackendService()
    private init() {}

    /// 稳定设备 id（复用 visitor id）。
    static var deviceId: String {
        StableDeviceID.current
    }

    /// 查询 Pro/额度。登录后同时传 user_id 和 email，避免跨端订阅只绑定在 Web user/device 上时漏判。
    func fetchStatus(userId: String?, email: String?) async -> ProStatusDTO? {
        var comps = URLComponents(string: Constants.API.proStatus)
        var items = [
            URLQueryItem(name: "device_id", value: Self.deviceId),
            URLQueryItem(name: "local_date", value: Self.localDay())
        ]
        if let userId = userId, !userId.isEmpty {
            items.append(URLQueryItem(name: "user_id", value: userId))
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            items.append(URLQueryItem(name: "email", value: email.lowercased()))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        Self.debugLog("status START device=\(Self.redact(Self.deviceId)) user=\(Self.redact(userId)) email=\(Self.redactEmail(email))")
        if email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            Self.debugLog("status EMAIL missing; request is anonymous/quota-only")
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else {
                Self.debugLog("status HTTP \(http.statusCode) body=\(Self.preview(data))")
                return nil
            }
            let status = try ProStatusDTO.decodeServerResponse(from: data)
            Self.debugLog("status DONE pro=\(status.pro ? "Y" : "N") plan=\(status.plan ?? "nil") free=\(status.freeRemaining.map(String.init) ?? "nil") listen=\(status.listenRemaining.map(String.init) ?? "nil")")
            return status
        } catch {
            Self.debugLog("status FAIL error=\(error.localizedDescription)")
            return nil   // fail-open
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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 401, canRefreshSession,
               await MobileSessionStore.shared.refreshSession() != nil {
                return await performAppleVerification(
                    signedTransaction: signedTransaction,
                    url: url,
                    canRefreshSession: false
                )
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

    /// 上报朗读秒数（增量）。fire-and-forget。
    func trackListen(seconds: Int, userId: String?, email: String?) async {
        guard seconds > 0, let url = URL(string: Constants.API.proListenTrack) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "device_id": Self.deviceId,
            "seconds": seconds,
            "local_date": Self.localDay()
        ]
        if let userId = userId, !userId.isEmpty { body["user_id"] = userId }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            body["email"] = email.lowercased()
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Self.debugLog("track START seconds=\(seconds) device=\(Self.redact(Self.deviceId)) user=\(Self.redact(userId)) email=\(Self.redactEmail(email))")
        if email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            Self.debugLog("track EMAIL missing; listen attribution is anonymous/quota-only")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
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
