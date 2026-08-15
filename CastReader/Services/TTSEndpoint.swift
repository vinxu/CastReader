//
//  TTSEndpoint.swift
//  CastReader
//
//  Compute routing is deliberately separate from ServiceRouting:
//  - ServiceRouting owns account, Pro, document and analytics identity.
//  - ComputeRouting selects the nearest TTS / QuickRead compute plane for the
//    current physical network. It never changes the signed-in account scope.
//

import CoreTelephony
import Foundation

enum ComputeRouting {
    struct EndpointProbe: Equatable, Sendable {
        let isReachable: Bool
        let latency: TimeInterval?

        static let unavailable = EndpointProbe(isReachable: false, latency: nil)
    }

    struct NetworkProbe: Equatable, Sendable {
        let china: EndpointProbe
        let global: EndpointProbe
        let country: NetworkCountryObservation?
    }

    /// Coarse first-party GeoIP observation. It intentionally carries no IP or
    /// account identifier; latency, locale, SIM and language are not geography.
    struct NetworkCountryObservation: Equatable, Sendable {
        let countryCode: String
    }

    struct Snapshot: Equatable, Sendable {
        let primary: ServiceRoute
        let provenance: Provenance
    }

    enum Provenance: String, Equatable, Sendable {
        case debugOverride
        case networkCountry
        case simCountry
        case mainlandTimeZone
        case safeGlobal
    }

    private static let mainlandTimeZones: Set<String> = [
        "Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Harbin", "Asia/Kashgar", "PRC",
    ]
    private static let probePath = "/api/mobile/network-region/v1"
    private static let runtime = ComputeRoutingRuntime()

    static var currentSnapshot: Snapshot {
        runtime.snapshot {
            resolve(
                timeZoneIdentifier: TimeZone.current.identifier,
                networkCountry: nil,
                simCountryCodes: currentSIMCountryCodes(),
                arguments: ProcessInfo.processInfo.arguments
            )
        }
    }

    static var current: ServiceRoute { currentSnapshot.primary }
    static var provenance: Provenance { currentSnapshot.provenance }

    @discardableResult
    static func freezeForCurrentProcess() -> Snapshot { currentSnapshot }

    /// Resolve and freeze the compute plane before APIService / QuickReadService
    /// singletons are constructed. The probes are first-party, carry no account
    /// credential or document text and have a strict shared deadline.
    @discardableResult
    static func bootstrapForCurrentProcess(
        timeZoneIdentifier: String = TimeZone.current.identifier,
        requestTimeout: TimeInterval = 2.5,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        simCountryCodes: [String]? = nil,
        precomputedProbe: NetworkProbe? = nil
    ) async -> Snapshot {
        if let frozen = runtime.frozenSnapshot { return frozen }
        let result: NetworkProbe
        if let precomputedProbe {
            result = precomputedProbe
        } else {
            result = await probeFirstPartyGateways(timeout: requestTimeout)
        }
        return runtime.snapshot {
            resolve(
                timeZoneIdentifier: timeZoneIdentifier,
                networkCountry: result.country,
                simCountryCodes: simCountryCodes ?? currentSIMCountryCodes(),
                arguments: arguments
            )
        }
    }

    /// Generation locality is independent from product/account scope. A
    /// process freezes exactly one route using the cross-platform signal order:
    /// Debug override -> first-party network country -> SIM -> time zone ->
    /// global. Latency/reachability, locale and system language are never used
    /// as geography.
    static func resolve(
        timeZoneIdentifier: String,
        networkCountry: NetworkCountryObservation? = nil,
        simCountryCodes: [String] = [],
        arguments: [String] = []
    ) -> Snapshot {
        if let forced = debugOverrideRoute(arguments) {
            return Snapshot(
                primary: forced,
                provenance: .debugOverride
            )
        }

        if let networkCountry {
            let code = networkCountry.countryCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if code == "CN" {
                return Snapshot(primary: .chinaGateway, provenance: .networkCountry)
            }
            if !code.isEmpty {
                return Snapshot(primary: .globalGateway, provenance: .networkCountry)
            }
        }

        let normalizedSIMCodes = simCountryCodes.compactMap(normalizedCountryCode)
        if !normalizedSIMCodes.isEmpty,
           normalizedSIMCodes.allSatisfy({ $0 == "CN" }) {
            return Snapshot(primary: .chinaGateway, provenance: .simCountry)
        }
        if !normalizedSIMCodes.isEmpty {
            return Snapshot(primary: .globalGateway, provenance: .simCountry)
        }

        if mainlandTimeZones.contains(timeZoneIdentifier) {
            return Snapshot(primary: .chinaGateway, provenance: .mainlandTimeZone)
        }
        return Snapshot(primary: .globalGateway, provenance: .safeGlobal)
    }

    private static func normalizedCountryCode(_ rawValue: String) -> String? {
        let code = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2,
              code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }) else {
            return nil
        }
        return code
    }

    /// SIM is deliberately below first-party GeoIP so roaming follows the
    /// current network. Multiple active SIMs choose CN only when every valid
    /// SIM is mainland. Mixed/overseas SIM evidence is ambiguous and therefore
    /// fails safely to global before time-zone fallback.
    static func currentSIMCountryCodes() -> [String] {
        let info = CTTelephonyNetworkInfo()
        let rawCodes: [String]
        if let carriers = info.serviceSubscriberCellularProviders, !carriers.isEmpty {
            rawCodes = carriers.values.compactMap(\.isoCountryCode)
        } else if let code = info.subscriberCellularProvider?.isoCountryCode {
            rawCodes = [code]
        } else {
            rawCodes = []
        }
        return Array(Set(rawCodes.compactMap(normalizedCountryCode))).sorted()
    }

    /// Local process arguments are a Debug-only test seam. The Release body is
    /// intentionally compiled to `nil`, so an App Store binary cannot honor a
    /// persisted or injected compute override.
    static func debugOverrideRoute(_ arguments: [String]) -> ServiceRoute? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-CastReaderComputeRoute"),
              index + 1 < arguments.count else { return nil }
        return ServiceRoute(rawValue: arguments[index + 1])
        #else
        return nil
        #endif
    }

    static func probeFirstPartyGateways(timeout: TimeInterval) async -> NetworkProbe {
        await probeFirstPartyGateways(timeout: timeout) { route, requestTimeout in
            await probe(route: route, timeout: requestTimeout)
        }
    }

    /// Test seam also centralizes the shared wall-clock deadline. Cancelling the
    /// group cancels URLSession.data(for:) for any ingress that is still stuck.
    static func probeFirstPartyGateways(
        timeout: TimeInterval,
        operation: @escaping @Sendable (ServiceRoute, TimeInterval) async -> GatewayProbeResult
    ) async -> NetworkProbe {
        enum ProbeEvent: Sendable {
            case result(ServiceRoute, GatewayProbeResult)
            case deadline
        }
        let deadline = max(0.25, timeout)
        var chinaResult = GatewayProbeResult(endpoint: .unavailable, country: nil)
        var globalResult = GatewayProbeResult(endpoint: .unavailable, country: nil)
        await withTaskGroup(of: ProbeEvent.self) { group in
            for route in ServiceRoute.allCases {
                group.addTask {
                    .result(route, await operation(route, deadline))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                } catch {
                    return .deadline
                }
                return .deadline
            }

            var completedRoutes = 0
            while let event = await group.next() {
                switch event {
                case .result(.chinaGateway, let result):
                    chinaResult = result
                    completedRoutes += 1
                case .result(.globalGateway, let result):
                    globalResult = result
                    completedRoutes += 1
                case .deadline:
                    group.cancelAll()
                    return
                }
                if completedRoutes == ServiceRoute.allCases.count {
                    group.cancelAll()
                    return
                }
            }
        }
        return NetworkProbe(
            china: chinaResult.endpoint,
            global: globalResult.endpoint,
            country: globalResult.country
        )
    }

    struct GatewayProbeResult: Sendable {
        let endpoint: EndpointProbe
        let country: NetworkCountryObservation?
    }

    private struct NetworkRegionPayload: Decodable {
        let schemaVersion: Int
        let countryCode: String?
        let mainlandChina: Bool?
        let ingress: String
    }

    private static func probe(route: ServiceRoute, timeout: TimeInterval) async -> GatewayProbeResult {
        guard let url = URL(string: route.apiGatewayBaseURL + probePath) else {
            return GatewayProbeResult(endpoint: .unavailable, country: nil)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = max(0.25, timeout)
        configuration.timeoutIntervalForResource = max(0.25, timeout)
        let session = OwnedAPIURLSession.make(
            configuration: configuration,
            route: route,
            rejectsEveryRedirect: true
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = max(0.25, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let startedAt = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= 2_048,
                  http.value(forHTTPHeaderField: "Content-Type")?
                    .lowercased().hasPrefix("application/json") == true,
                  let payload = try? JSONDecoder().decode(NetworkRegionPayload.self, from: data),
                  payload.schemaVersion == 1,
                  payload.ingress == route.rawValue else {
                return GatewayProbeResult(endpoint: .unavailable, country: nil)
            }
            let endpoint = EndpointProbe(
                isReachable: true,
                latency: max(0, Date().timeIntervalSince(startedAt))
            )
            guard route == .globalGateway else {
                return GatewayProbeResult(endpoint: endpoint, country: nil)
            }
            let country = validatedCountryObservation(payload)
            return GatewayProbeResult(endpoint: endpoint, country: country)
        } catch {
            return GatewayProbeResult(endpoint: .unavailable, country: nil)
        }
    }

    private static func validatedCountryObservation(
        _ payload: NetworkRegionPayload
    ) -> NetworkCountryObservation? {
        guard let rawCode = payload.countryCode else { return nil }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2,
              code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) }),
              let mainland = payload.mainlandChina,
              mainland == (code == "CN") else {
            return nil
        }
        return NetworkCountryObservation(countryCode: code)
    }

    #if DEBUG
    static func resetProcessSnapshotForTesting() {
        runtime.reset()
    }
    #endif
}

private final class ComputeRoutingRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrozenSnapshot: ComputeRouting.Snapshot?

    var frozenSnapshot: ComputeRouting.Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedFrozenSnapshot
    }

    func snapshot(_ resolver: () -> ComputeRouting.Snapshot) -> ComputeRouting.Snapshot {
        lock.lock()
        defer { lock.unlock() }
        if let storedFrozenSnapshot { return storedFrozenSnapshot }
        let snapshot = resolver()
        storedFrozenSnapshot = snapshot
        return snapshot
    }

    #if DEBUG
    func reset() {
        lock.lock()
        storedFrozenSnapshot = nil
        lock.unlock()
    }
    #endif
}

enum TTSEndpoint {
    static let globalBase = ServiceRoute.globalGateway.apiGatewayBaseURL
    static let chinaMainlandBase = ServiceRoute.chinaGateway.apiGatewayBaseURL

    static func primaryBase() -> String {
        ComputeRouting.current.apiGatewayBaseURL
    }

    /// Pure compatibility seam retained for endpoint policy tests.
    static func primaryBase(isMainlandChina: Bool) -> String {
        isMainlandChina ? chinaMainlandBase : globalBase
    }

    /// Generation flows are route-frozen. A TTS payload is never resent across
    /// borders after a network or server failure.
    static func fallbackBase() -> String? {
        nil
    }

    static func fallbackBase(isMainlandChina: Bool) -> String? {
        nil
    }

    static func candidateRoutes() -> [ServiceRoute] {
        [ComputeRouting.current]
    }

    static func partlyURL(base: String) -> String {
        "\(base)/api/captioned_speech_partly"
    }

    @discardableResult
    static func freezeForCurrentProcess() -> String {
        _ = ComputeRouting.freezeForCurrentProcess()
        return primaryBase()
    }

    /// 旧客户端的远程节点配置已退出新版路径；保留签名便于渐进清理启动调用。
    static func refreshRemoteConfig() async {}

    #if DEBUG
    static func resetProcessSnapshotForTesting() {
        ComputeRouting.resetProcessSnapshotForTesting()
    }
    #endif
}
