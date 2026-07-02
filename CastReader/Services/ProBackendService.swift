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
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try ProStatusDTO.decodeServerResponse(from: data)
        } catch {
            return nil   // fail-open
        }
    }

    /// 上报朗读秒数（增量）。fire-and-forget。
    func trackListen(seconds: Int, userId: String?, email: String?) async {
        guard seconds > 0, let url = URL(string: Constants.API.proListenTrack) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["device_id": Self.deviceId, "seconds": seconds]
        if let userId = userId, !userId.isEmpty { body["user_id"] = userId }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            body["email"] = email.lowercased()
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    static func localDay() -> String {
        let f = DateFormatter()
        f.calendar = .current; f.locale = .current; f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
