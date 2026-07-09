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
        let d = UserDefaults.standard
        if let id = d.string(forKey: Constants.Storage.visitorIdKey) { return id }
        let id = UUID().uuidString
        d.set(id, forKey: Constants.Storage.visitorIdKey)
        return id
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
