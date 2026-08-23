//
//  ProBackendService.swift
//  CastReader
//
//  Build-39 原生账号/Pro 后端。cms_ session 是唯一账号权威；客户端不再把
//  user_id/email 送到旧公开接口。服务端只从 cms_ 的 canonical user 和 ingress
//  route 派生额度主体；客户端 device id 仅作为向后兼容字段，不能改变额度归属。
//

import Foundation
import StoreKit

struct ProAccountDTO: Decodable, Equatable {
    let name: String?
    let email: String?
    let image: String?
}

struct GrowthConfigDTO: Decodable, Equatable {
    let configId: String
    let market: String
    let eligible: Bool
    let assignedAt: String?
    let killSwitch: Bool
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
    let grantListenMax: Int?
    let grantExplainMax: Int?
    let monthlyListenMax: Int?
    let monthlyListenRemaining: Int?
    let monthlyExplainMax: Int?
    let monthlyExplainRemaining: Int?
    let growthConfig: GrowthConfigDTO?

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
        grantExplainRemaining: Int? = nil,
        grantListenMax: Int? = nil,
        grantExplainMax: Int? = nil,
        monthlyListenMax: Int? = nil,
        monthlyListenRemaining: Int? = nil,
        monthlyExplainMax: Int? = nil,
        monthlyExplainRemaining: Int? = nil,
        growthConfig: GrowthConfigDTO? = nil
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
        self.grantListenMax = grantListenMax
        self.grantExplainMax = grantExplainMax
        self.monthlyListenMax = monthlyListenMax
        self.monthlyListenRemaining = monthlyListenRemaining
        self.monthlyExplainMax = monthlyExplainMax
        self.monthlyExplainRemaining = monthlyExplainRemaining
        self.growthConfig = growthConfig
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

struct ProListenTrackDTO: Decodable, Equatable, Sendable {
    let seconds: Int
    let limit: Int
    let remaining: Int
    let grantListenRemaining: Int?
    let quotaPolicy: String?
}

enum ProListenTrackOutcome: Equatable, Sendable {
    case success(ProListenTrackDTO)
    case growthIdentityRequired
    case usageEventConflict
    case unauthorized
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

    struct GrowthClientContext: Equatable, Sendable {
        let analyticsAnonymousId: String
        let stableDeviceId: String
        let appVersion: String
        let appBuild: String?
        let storefrontCountry: String?
    }

    private static func growthClientContext() async -> GrowthClientContext {
        let analyticsAnonymousId = await ProductAnalytics.shared.privacySafeAnonymousId
        let storefrontCountry = Self.normalizedStorefrontCountry(
            await Storefront.current?.countryCode
        )
        return GrowthClientContext(
            analyticsAnonymousId: analyticsAnonymousId,
            stableDeviceId: deviceId,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            storefrontCountry: storefrontCountry
        )
    }

    /// 查询 Pro/额度。账号只由 cms_ session 解析；query 不包含 user_id/email，
    /// 服务端也不会把可轮换的 device_id 当作 v2 额度主键。
    func fetchStatus() async -> ProStatusFetchOutcome {
        let context = await Self.growthClientContext()
        guard let url = Self.makeStatusURL(
            endpoint: Constants.API.mobileProStatusV2,
            context: context,
            localDate: Self.localDay()
        ) else { return .unavailable }
        return await performStatus(url: url, canRefreshSession: true)
    }

    static func makeStatusURL(
        endpoint: String,
        context: GrowthClientContext,
        localDate: String
    ) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        var items = [
            URLQueryItem(name: "device_id", value: context.stableDeviceId),
            URLQueryItem(name: "analytics_anonymous_id", value: context.analyticsAnonymousId),
            URLQueryItem(name: "local_date", value: localDate),
            URLQueryItem(name: "app_version", value: context.appVersion),
        ]
        if let appBuild = context.appBuild, !appBuild.isEmpty {
            items.append(URLQueryItem(name: "app_build", value: appBuild))
        }
        if let country = context.storefrontCountry, !country.isEmpty {
            items.append(URLQueryItem(name: "storefront_country", value: country))
        }
        components.queryItems = items
        return components.url
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
            if let config = status.growthConfig {
                await ProductAnalytics.shared.trackGrowthConfigAssigned(
                    configId: config.configId,
                    market: Self.analyticsGrowthMarket(config.market).rawValue,
                    eligibility: (config.eligible && !config.killSwitch)
                        ? AnalyticsGrowthEligibility.eligible.rawValue
                        : AnalyticsGrowthEligibility.ineligible.rawValue
                )
            }
            Self.debugLog("status DONE pro=\(status.pro ? "Y" : "N") plan=\(status.plan ?? "nil") free=\(status.freeRemaining.map(String.init) ?? "nil") listen=\(status.listenRemaining.map(String.init) ?? "nil")")
            return .success(status)
        } catch {
            Self.debugLog("status FAIL error=\(error.localizedDescription)")
            return .unavailable
        }
    }

    static func analyticsGrowthMarket(_ rawValue: String) -> AnalyticsGrowthMarket {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "US", "USA": return .us
        case "GB", "GBR", "UK": return .gb
        default: return .other
        }
    }

    static func normalizedStorefrontCountry(_ rawValue: String?) -> String? {
        guard let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(), !value.isEmpty else { return nil }
        switch value {
        case "USA": return "US"
        case "GBR", "UK": return "GB"
        default: return value.count == 2 ? value : nil
        }
    }

    /// Links the install-scoped analytics id and Keychain-stable device id to
    /// the canonical account derived by the server from the cms_ bearer. No
    /// client-supplied user id is present in this contract.
    func linkGrowthIdentity() async -> Bool {
        guard let url = URL(string: Constants.API.mobileGrowthIdentityLink) else {
            return false
        }
        let context = await Self.growthClientContext()
        return await performGrowthIdentityLink(
            url: url,
            context: context,
            canRefreshSession: true
        )
    }

    private func performGrowthIdentityLink(
        url: URL,
        context: GrowthClientContext,
        canRefreshSession: Bool
    ) async -> Bool {
        var token = await MobileSessionStore.shared.sessionToken()
        if token == nil, canRefreshSession {
            token = await MobileSessionStore.shared.refreshSession()
        }
        guard let token, !token.isEmpty else {
            Self.debugLog("growth-identity SKIP mobile-session-missing")
            return false
        }
        let request: URLRequest
        do {
            request = try Self.makeGrowthIdentityLinkRequest(
                url: url,
                bearerToken: token,
                context: context
            )
        } catch {
            return false
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 401, canRefreshSession,
               await MobileSessionStore.shared.refreshSession() != nil {
                return await performGrowthIdentityLink(
                    url: url,
                    context: context,
                    canRefreshSession: false
                )
            }
            if http.statusCode == 401 {
                await MobileSessionStore.shared.rejectSession(token)
                return false
            }
            guard (200..<300).contains(http.statusCode),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (root["code"] as? Int) == 0,
                  let payload = root["data"] as? [String: Any],
                  payload["linked"] as? Bool == true else {
                Self.debugLog(
                    "growth-identity HTTP \(http.statusCode) body=\(Self.preview(data))"
                )
                return false
            }
            Self.debugLog("growth-identity DONE")
            return true
        } catch {
            Self.debugLog("growth-identity FAIL error=\(error.localizedDescription)")
            return false
        }
    }

    static func makeGrowthIdentityLinkRequest(
        url: URL,
        bearerToken: String,
        context: GrowthClientContext
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        var body: [String: Any] = [
            "analytics_anonymous_id": context.analyticsAnonymousId,
            "stable_device_id": context.stableDeviceId,
            "app_version": context.appVersion,
        ]
        if let appBuild = context.appBuild, !appBuild.isEmpty {
            body["app_build"] = appBuild
        }
        if let country = context.storefrontCountry, !country.isEmpty {
            body["storefront_country"] = country
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
    @discardableResult
    func trackListen(seconds: Int) async -> ProListenTrackOutcome {
        guard seconds > 0,
              let url = URL(string: Constants.API.mobileProListenTrackV2) else {
            return .unavailable
        }
        let context = await Self.growthClientContext()
        return await performListenTrack(
            seconds: seconds,
            usageEventId: UUID().uuidString,
            analyticsAnonymousId: context.analyticsAnonymousId,
            url: url,
            canRefreshSession: true,
            canRetryTransport: true
        )
    }

    private func performListenTrack(
        seconds: Int,
        usageEventId: String,
        analyticsAnonymousId: String,
        url: URL,
        canRefreshSession: Bool,
        canRetryTransport: Bool
    ) async -> ProListenTrackOutcome {
        var token = await MobileSessionStore.shared.sessionToken()
        if token == nil, canRefreshSession {
            token = await MobileSessionStore.shared.refreshSession()
        }
        guard let token, !token.isEmpty else {
            Self.debugLog("track-v2 BLOCK mobile-session-missing")
            return .unauthorized
        }
        let request: URLRequest
        do {
            request = try Self.makeListenTrackRequest(
                url: url,
                bearerToken: token,
                analyticsAnonymousId: analyticsAnonymousId,
                usageEventId: usageEventId,
                seconds: seconds
            )
        } catch {
            return .unavailable
        }
        Self.debugLog("track-v2 START seconds=\(seconds) usage=\(Self.redact(usageEventId))")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            if http.statusCode == 401, canRefreshSession,
               await MobileSessionStore.shared.refreshSession() != nil {
                return await performListenTrack(
                    seconds: seconds,
                    usageEventId: usageEventId,
                    analyticsAnonymousId: analyticsAnonymousId,
                    url: url,
                    canRefreshSession: false,
                    canRetryTransport: canRetryTransport
                )
            }
            if http.statusCode == 401 {
                await MobileSessionStore.shared.rejectSession(token)
                return .unauthorized
            }
            if (200..<300).contains(http.statusCode) {
                guard let payload = Self.decodeListenTrackResponse(data) else {
                    return .unavailable
                }
                return .success(payload)
            }
            let serverCode = Self.serverErrorCode(from: data)
            if http.statusCode == 422,
               serverCode == "GROWTH_USAGE_IDENTITY_REQUIRED" {
                return .growthIdentityRequired
            }
            if http.statusCode == 409,
               serverCode == "GROWTH_USAGE_EVENT_CONFLICT" {
                return .usageEventConflict
            }
            if !(200..<300).contains(http.statusCode) {
                if canRetryTransport, (500..<600).contains(http.statusCode) {
                    return await performListenTrack(
                        seconds: seconds,
                        usageEventId: usageEventId,
                        analyticsAnonymousId: analyticsAnonymousId,
                        url: url,
                        canRefreshSession: false,
                        canRetryTransport: false
                    )
                }
                Self.debugLog("track HTTP \(http.statusCode) body=\(Self.preview(data))")
            }
            return .unavailable
        } catch {
            if canRetryTransport {
                return await performListenTrack(
                    seconds: seconds,
                    usageEventId: usageEventId,
                    analyticsAnonymousId: analyticsAnonymousId,
                    url: url,
                    canRefreshSession: false,
                    canRetryTransport: false
                )
            }
            Self.debugLog("track FAIL error=\(error.localizedDescription)")
            return .unavailable
        }
    }

    static func makeListenTrackRequest(
        url: URL,
        bearerToken: String,
        analyticsAnonymousId: String,
        usageEventId: String,
        seconds: Int
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "analytics_anonymous_id": analyticsAnonymousId,
            "usage_event_id": usageEventId,
            "seconds": seconds,
        ])
        return request
    }

    static func decodeListenTrackResponse(_ data: Data) -> ProListenTrackDTO? {
        struct Envelope: Decodable { let data: ProListenTrackDTO }
        let decoder = JSONDecoder()
        return (try? decoder.decode(Envelope.self, from: data).data)
            ?? (try? decoder.decode(ProListenTrackDTO.self, from: data))
    }

    static func serverErrorCode(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (root["errorCode"] as? String)
            ?? (root["code"] as? String)
            ?? (root["error"] as? String)
            ?? ((root["error"] as? [String: Any])?["code"] as? String)
            ?? ((root["data"] as? [String: Any])?["code"] as? String)
            ?? ((root["data"] as? [String: Any])?["error"] as? String)
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
