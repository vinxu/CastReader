//
//  ServiceRouting.swift
//  CastReader
//
//  自有后端线路选择。它与 AppRegion（发行体验）严格分离：
//  - AppRegion 决定引导、默认书库与中国区功能呈现；
//  - ServiceRoute 决定账号、Pro、埋点、文档、上传等账号业务走哪套网络；
//  - TTS / QuickRead / 音色物料由独立 ComputeRouting 按用户位置决定。
//
//  安全原则：新版全球网关永远是默认值。配置缺失、过期、不可达、格式异常或
//  当前 build 不在灰度范围内时，一律回到 globalGateway。旧已发布二进制的
//  历史路径由服务端继续兼容，不是新版 App 的第三条线路。线路在进程启动时冻结，
//  设置页和后台刷新只影响下次完整启动，避免同一会话跨入口发送 token 或业务请求。
//

import Foundation

/// Persisted region/route switches are test instrumentation. They may survive
/// an overwrite install, so production authorization must come from the signed
/// distribution environment rather than an account, email or stored value.
enum DistributionTestingPolicy {
    static let internalDistributionControlsInfoKey =
        "CastReaderInternalDistributionControlsEnabled"
    static let allowPersistedOverridesLaunchArgument =
        "-CastReaderAllowPersistedDistributionOverrides"

    static var allowsPersistedOverrides: Bool {
        #if DEBUG
        return true
        #else
        // App Store / Release builds ignore every local distribution override.
        // Storefront and the signed backend rollout remain the only authorities.
        return false
        #endif
    }

    /// The signed build setting is the primary authorization for non-Debug
    /// distribution controls. `sandboxReceipt` is only a second condition: App
    /// Review may run a normal Release archive against the sandbox, so the
    /// receipt alone must never expose or honor persisted region/route switches.
    static func allowsPersistedOverrides(
        isDebugBuild: Bool,
        isInternalDistributionBuild: Bool,
        appStoreReceiptURL: URL?,
        arguments _: [String]
    ) -> Bool {
        if isDebugBuild { return true }
        guard isInternalDistributionBuild else { return false }
        return appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Xcode expands the build setting in Info.plist as either NSNumber/Bool or
    /// a string depending on the build pipeline. Anything except an explicit
    /// true value fails closed.
    static func internalDistributionControlsEnabled(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        guard let raw = value as? String else { return false }
        return ["1", "true", "yes"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

enum ServiceRoute: String, CaseIterable, Codable {
    /// 新版全球线路：所有 CastReader 自有业务都从 api.castreader.ai 进入。
    case globalGateway = "global"

    /// 所有 CastReader 自有业务统一进入备案网关；平台书架与 Apple/Google 等第三方
    /// 服务不属于这层路由。
    case chinaGateway = "cn"

    var apiGatewayBaseURL: String {
        switch self {
        case .globalGateway: return "https://api.castreader.ai"
        case .chinaGateway: return "https://api.castreader.cn"
        }
    }

    /// QuickRead has its own mainland ingress so document text does not make an
    /// unnecessary trip through the general CN gateway (or any `.ai`
    /// QuickRead origin). Global keeps the already-tested unified gateway.
    var quickReadBaseURL: String {
        switch self {
        case .globalGateway: return apiGatewayBaseURL
        case .chinaGateway: return "https://quickread.castreader.cn"
        }
    }

    var webBaseURL: String {
        apiGatewayBaseURL
    }

    var displayName: String {
        switch self {
        case .globalGateway: return "全球网关"
        case .chinaGateway: return "中国备案网关"
        }
    }

    /// 全球网关继续使用历史 key，保证升级不丢登录/额度/待发送事件；中国线路使用
    /// 客户端独立命名空间，避免把一个入口签发的 session、额度缓存或待发事件
    /// 误送到另一个入口。服务端 canonical 账号与 Apple 账本仍必须共享。
    func isolatedStorageKey(_ legacyKey: String) -> String {
        switch self {
        case .globalGateway: return legacyKey
        case .chinaGateway: return "\(legacyKey).cn"
        }
    }

    /// 只用于读取旧 Debug/显式 Internal 构建在本机留下的覆盖值。远程配置和
    /// 启动参数必须使用严格的 `global` / `cn`，不得对服务器开放模糊别名。
    static func fromPersistedRawValue(_ rawValue: String) -> ServiceRoute? {
        if rawValue == "legacy" { return .globalGateway }
        return ServiceRoute(rawValue: rawValue)
    }
}

enum ServiceRouting {
    struct Snapshot: Equatable {
        let route: ServiceRoute
        let provenance: Provenance
    }

    enum Provenance: String {
        case launchArgument = "启动参数"
        case localOverride = "App 手动覆盖"
        case backend = "后台配置"
        case safeDefault = "安全默认"
    }

    enum RefreshOutcome: Equatable {
        case updated(ServiceRoute)
        case skippedOutsideChina
        case buildNotEligible
        case failed

        var displayMessage: String {
            switch self {
            case .updated(let route):
                return "后台配置已刷新：\(route.displayName)，下次启动生效"
            case .skippedOutsideChina:
                return "后台线路只对中国发行区域的“跟随后台”模式生效"
            case .buildNotEligible:
                return "当前测试 Build 不在后台灰度范围内，将使用全球网关"
            case .failed:
                return "后台配置不可用，已安全回退到全球网关"
            }
        }
    }

    struct RemoteConfiguration: Decodable, Equatable {
        let schemaVersion: Int
        let iosChinaServiceRoute: String
        let minimumBuild: Int?
        let maximumBuild: Int?
        let cacheSeconds: Int

        func validatedRoute(buildNumber: Int) -> ServiceRoute? {
            guard schemaVersion == 1,
                  let route = ServiceRoute(rawValue: iosChinaServiceRoute) else {
                return nil
            }

            // Enabling the new gateway is a fail-closed rollout. Never accept a
            // malformed/proxied `{ route: "cn" }` response without an explicit,
            // internally consistent build window, even if the admin API normally
            // enforces that contract. The global safe route may remain unbounded.
            if route == .chinaGateway {
                guard let minimumBuild, let maximumBuild,
                      minimumBuild <= maximumBuild else { return nil }
            } else if let minimumBuild, let maximumBuild,
                      minimumBuild > maximumBuild {
                return nil
            }

            guard minimumBuild.map({ buildNumber >= $0 }) ?? true,
                  maximumBuild.map({ buildNumber <= $0 }) ?? true else {
                return nil
            }
            return route
        }
    }

    struct BackendCacheRecord: Codable, Equatable {
        let route: ServiceRoute
        let minimumBuild: Int?
        let maximumBuild: Int?
        let expiresAt: Date
        let fetchedAt: Date

        init(
            route: ServiceRoute,
            minimumBuild: Int?,
            maximumBuild: Int?,
            expiresAt: Date,
            fetchedAt: Date
        ) {
            self.route = route
            self.minimumBuild = minimumBuild
            self.maximumBuild = maximumBuild
            self.expiresAt = expiresAt
            self.fetchedAt = fetchedAt
        }

        private enum CodingKeys: String, CodingKey {
            case route, minimumBuild, maximumBuild, expiresAt, fetchedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawRoute = try container.decode(String.self, forKey: .route)
            guard let route = ServiceRoute.fromPersistedRawValue(rawRoute) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .route,
                    in: container,
                    debugDescription: "Unsupported persisted service route"
                )
            }
            self.route = route
            minimumBuild = try container.decodeIfPresent(Int.self, forKey: .minimumBuild)
            maximumBuild = try container.decodeIfPresent(Int.self, forKey: .maximumBuild)
            expiresAt = try container.decode(Date.self, forKey: .expiresAt)
            fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(route.rawValue, forKey: .route)
            try container.encodeIfPresent(minimumBuild, forKey: .minimumBuild)
            try container.encodeIfPresent(maximumBuild, forKey: .maximumBuild)
            try container.encode(expiresAt, forKey: .expiresAt)
            try container.encode(fetchedAt, forKey: .fetchedAt)
        }

        func validatedRoute(buildNumber: Int) -> ServiceRoute? {
            if route == .chinaGateway {
                guard let minimumBuild, let maximumBuild,
                      minimumBuild <= maximumBuild else { return nil }
            } else if let minimumBuild, let maximumBuild,
                      minimumBuild > maximumBuild {
                return nil
            }
            guard minimumBuild.map({ buildNumber >= $0 }) ?? true,
                  maximumBuild.map({ buildNumber <= $0 }) ?? true else {
                return nil
            }
            return route
        }
    }

    private enum Key {
        /// 空值表示“跟随后台”。
        static let override = "serviceRouting.v1.override"
        /// 单个 Codable blob 原子写入，避免进程在三字段写到一半时留下新旧组合。
        static let backendConfiguration = "serviceRouting.v1.backendConfiguration"
    }

    private static let remoteConfigurationPath = "/api/mobile/runtime-config/v1"

    /// The rollout document is fetched from the filed mainland control plane for
    /// an authoritative CHN storefront. This request happens before the business
    /// route is frozen, so it must not derive its ingress from `current` (which
    /// would itself freeze the safe global default on a first install).
    static func remoteConfigurationURL(for route: ServiceRoute) -> String {
        route.apiGatewayBaseURL + remoteConfigurationPath
    }

    static var remoteConfigurationURL: String {
        remoteConfigurationURL(for: current)
    }

    // 配置每次启动都会刷新；这里是“可供下一次启动使用”的最长有效期，不是轮询
    // 间隔。有效期过短会导致用户隔天启动时永远先回 global、刷新后又不重启。
    private static let minimumCacheSeconds = 5 * 60
    private static let maximumCacheSeconds = 7 * 24 * 60 * 60
    private static let runtime = ServiceRoutingRuntime()
    private static var defaults: UserDefaults { .standard }

    static var overrideDefaultsKey: String { Key.override }
    static var backendConfigurationDefaultsKey: String { Key.backendConfiguration }

    static var overrideRoute: ServiceRoute? {
        get {
            guard allowsLocalOverride else { return nil }
            return defaults.string(forKey: Key.override)
                .flatMap(ServiceRoute.fromPersistedRawValue)
        }
        set {
            guard allowsLocalOverride else {
                defaults.removeObject(forKey: Key.override)
                return
            }
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Key.override)
            } else {
                defaults.removeObject(forKey: Key.override)
            }
        }
    }

    /// 当前进程的不可变线路快照。
    static var currentSnapshot: Snapshot {
        runtime.snapshot { resolve() }
    }

    static var current: ServiceRoute { currentSnapshot.route }
    static var provenance: Provenance { currentSnapshot.provenance }

    /// 根据磁盘上的最新设置计算“下次完整启动”会使用的线路；不会改变当前进程。
    static var nextLaunchSnapshot: Snapshot { resolve() }

    /// 必须在任何会捕获 endpoint 的单例初始化前调用。
    @discardableResult
    static func freezeForCurrentProcess() -> Snapshot { currentSnapshot }

    /// Cold-start bootstrap. It is the only production path allowed to refresh
    /// the CHN rollout document before freezing the route. Explicit launch/local
    /// test overrides stay deterministic and skip the remote control plane.
    /// Re-entrancy is harmless: once frozen, the first snapshot always wins.
    @discardableResult
    static func bootstrapForCurrentProcess(
        appRegionResolution: AppRegion.Resolution,
        session: URLSession? = nil,
        now: Date = Date(),
        buildNumber: Int = currentBuildNumber,
        requestTimeout: TimeInterval = 4,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        allowLocalOverride: Bool = allowsLocalOverride
    ) async -> Snapshot {
        if let frozen = runtime.frozenSnapshot { return frozen }

        let preflight = resolve(
            defaults: defaults,
            arguments: arguments,
            now: now,
            appRegion: appRegionResolution.region,
            isAppRegionAuthoritative: appRegionResolution.isAuthoritative,
            buildNumber: buildNumber,
            allowLocalOverride: allowLocalOverride
        )
        if preflight.provenance == .launchArgument || preflight.provenance == .localOverride {
            return runtime.snapshot { preflight }
        }

        // `-CastReaderRegion` is product-UI instrumentation. UI tests that only
        // need the CN login/onboarding surface must not depend on a live control
        // plane; tests that exercise networking already pass an explicit
        // `-CastReaderServiceRoute` and are handled by the branch above.
        if appRegionResolution.provenance == .launchArgument {
            return runtime.snapshot {
                Snapshot(route: .globalGateway, provenance: .safeDefault)
            }
        }

        if appRegionResolution.isAuthoritative, appRegionResolution.region == .cn {
            _ = await refreshBackendConfiguration(
                session: session,
                now: now,
                buildNumber: buildNumber,
                requestTimeout: requestTimeout,
                appRegionResolution: appRegionResolution
            )
        }

        return runtime.snapshot {
            resolve(
                defaults: defaults,
                arguments: arguments,
                now: now,
                appRegion: appRegionResolution.region,
                isAppRegionAuthoritative: appRegionResolution.isAuthoritative,
                buildNumber: buildNumber,
                allowLocalOverride: allowLocalOverride
            )
        }
    }

    /// 纯解析入口，供严格的路由优先级与过期行为单测使用。
    static func resolve(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        now: Date = Date(),
        appRegion: AppRegion = AppRegion.current,
        isAppRegionAuthoritative: Bool = AppRegion.isAuthoritative,
        buildNumber: Int = currentBuildNumber,
        allowLocalOverride: Bool = allowsLocalOverride
    ) -> Snapshot {
        #if DEBUG
        if arguments.contains("-CastReaderServiceRoute") {
            guard let route = launchArgumentRoute(arguments) else {
                return Snapshot(route: .globalGateway, provenance: .safeDefault)
            }
            return Snapshot(route: route, provenance: .launchArgument)
        }
        #endif

        if allowLocalOverride,
           let raw = defaults.string(forKey: Key.override), !raw.isEmpty {
            guard let route = ServiceRoute.fromPersistedRawValue(raw) else {
                // 一个损坏的手动覆盖值不能悄悄落到可能为 CN 的后台缓存。
                return Snapshot(route: .globalGateway, provenance: .safeDefault)
            }
            return Snapshot(route: route, provenance: .localOverride)
        }

        // 后台只能控制已被 App Store storefront（或内部发行区域覆盖）明确判定为
        // 中国大陆的客户端。首启时区推断绝不能直接把网络切到新网关。
        guard isAppRegionAuthoritative, appRegion == .cn else {
            return Snapshot(route: .globalGateway, provenance: .safeDefault)
        }

        if let record = cachedBackendRecord(defaults: defaults),
           record.expiresAt > now,
           let route = record.validatedRoute(buildNumber: buildNumber) {
            return Snapshot(route: route, provenance: .backend)
        }

        return Snapshot(route: .globalGateway, provenance: .safeDefault)
    }

    static func launchArgumentRoute(_ arguments: [String]) -> ServiceRoute? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: "-CastReaderServiceRoute"),
              index + 1 < arguments.count else { return nil }
        return ServiceRoute(rawValue: arguments[index + 1])
        #else
        return nil
        #endif
    }

    static var cachedBackendRoute: ServiceRoute? {
        cachedBackendRecord(defaults: defaults)?.route
    }

    static var cachedBackendExpiresAt: Date? {
        cachedBackendRecord(defaults: defaults)?.expiresAt
    }

    static var cachedBackendFetchedAt: Date? {
        cachedBackendRecord(defaults: defaults)?.fetchedAt
    }

    static var isBackendCacheValid: Bool {
        guard let record = cachedBackendRecord(defaults: defaults),
              record.expiresAt > Date(),
              record.validatedRoute(buildNumber: currentBuildNumber) != nil else {
            return false
        }
        return true
    }

    static var currentBuildNumber: Int {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return Int(raw ?? "") ?? 0
    }

    static let allowLocalOverrideLaunchArgument =
        DistributionTestingPolicy.allowPersistedOverridesLaunchArgument

    /// A persisted switch is a testing facility, never a production entitlement.
    /// App Store upgrades preserve UserDefaults, so a value written by Debug or
    /// an internal distribution must not become a permanent production route.
    static var allowsLocalOverride: Bool {
        DistributionTestingPolicy.allowsPersistedOverrides
    }

    static func localOverrideAllowed(
        isDebugBuild: Bool,
        isInternalDistributionBuild: Bool = false,
        appStoreReceiptURL: URL?,
        arguments: [String]
    ) -> Bool {
        DistributionTestingPolicy.allowsPersistedOverrides(
            isDebugBuild: isDebugBuild,
            isInternalDistributionBuild: isInternalDistributionBuild,
            appStoreReceiptURL: appStoreReceiptURL,
            arguments: arguments
        )
    }

    /// Remove a Debug/internal-build value before production freezes its route. The
    /// resolver also ignores it, so a storage failure could never make it live.
    static func discardDisallowedLocalOverride(
        defaults: UserDefaults = .standard,
        allowLocalOverride: Bool = allowsLocalOverride
    ) {
        guard !allowLocalOverride else { return }
        defaults.removeObject(forKey: Key.override)
    }

    /// Rewrite only local values produced by an earlier Debug/internal build.
    /// Remote payload parsing remains strict and never accepts `legacy`.
    static func migratePersistedAliases(
        defaults: UserDefaults = .standard,
        allowLocalOverride: Bool = allowsLocalOverride
    ) {
        if allowLocalOverride,
           defaults.string(forKey: Key.override) == "legacy" {
            defaults.set(ServiceRoute.globalGateway.rawValue, forKey: Key.override)
        }
        guard let data = defaults.data(forKey: Key.backendConfiguration),
              String(data: data, encoding: .utf8)?.contains(#""route":"legacy""#) == true,
              let record = try? JSONDecoder().decode(BackendCacheRecord.self, from: data),
              let migrated = try? JSONEncoder().encode(record) else { return }
        defaults.set(migrated, forKey: Key.backendConfiguration)
    }

    /// 从中国备案控制面读取不含 URL/密钥的共享枚举配置。启动闸门在线路冻结前
    /// 调用它；设置页在冻结后调用时，结果只影响下次启动。任何异常都会
    /// 清除远端缓存，安全回到 globalGateway。
    static func refreshBackendConfiguration(
        session: URLSession? = nil,
        now: Date = Date(),
        buildNumber: Int = currentBuildNumber,
        requestTimeout: TimeInterval = 4,
        appRegionResolution: AppRegion.Resolution? = nil
    ) async -> RefreshOutcome {
        let resolution = appRegionResolution ?? AppRegion.resolve()
        guard resolution.isAuthoritative, resolution.region == .cn else {
            return .skippedOutsideChina
        }
        let controlPlaneRoute = ServiceRoute.chinaGateway
        guard let url = URL(string: remoteConfigurationURL(for: controlPlaneRoute)) else {
            clearBackendConfiguration()
            return .failed
        }
        let requestSession = session ?? OwnedAPIURLSession.controlPlane(for: controlPlaneRoute)

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = requestTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(String(buildNumber), forHTTPHeaderField: "x-castreader-build")

            let (data, response) = try await requestSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                clearBackendConfiguration()
                return .failed
            }

            let payload = try JSONDecoder().decode(RemoteConfiguration.self, from: data)
            guard let route = payload.validatedRoute(buildNumber: buildNumber) else {
                clearBackendConfiguration()
                let hasValidSchemaAndRoute = payload.schemaVersion == 1
                    && ServiceRoute(rawValue: payload.iosChinaServiceRoute) != nil
                return hasValidSchemaAndRoute ? .buildNotEligible : .failed
            }

            let ttl = min(
                max(payload.cacheSeconds, minimumCacheSeconds),
                maximumCacheSeconds
            )
            let record = BackendCacheRecord(
                route: route,
                minimumBuild: payload.minimumBuild,
                maximumBuild: payload.maximumBuild,
                expiresAt: now.addingTimeInterval(TimeInterval(ttl)),
                fetchedAt: now
            )
            defaults.set(try JSONEncoder().encode(record), forKey: Key.backendConfiguration)
            return .updated(route)
        } catch {
            clearBackendConfiguration()
            return .failed
        }
    }

    static func clearBackendConfiguration() {
        defaults.removeObject(forKey: Key.backendConfiguration)
    }

    static func cachedBackendRecord(defaults: UserDefaults = .standard) -> BackendCacheRecord? {
        guard let data = defaults.data(forKey: Key.backendConfiguration) else { return nil }
        return try? JSONDecoder().decode(BackendCacheRecord.self, from: data)
    }

    #if DEBUG
    /// XCTest 共用宿主进程；每个路由用例必须显式清掉被冻结的生产快照。
    static func resetProcessSnapshotForTesting() {
        runtime.reset()
    }
    #endif
}

private final class ServiceRoutingRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrozenSnapshot: ServiceRouting.Snapshot?

    var frozenSnapshot: ServiceRouting.Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedFrozenSnapshot
    }

    func snapshot(_ resolver: () -> ServiceRouting.Snapshot) -> ServiceRouting.Snapshot {
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
