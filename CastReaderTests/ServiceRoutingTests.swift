//
//  ServiceRoutingTests.swift
//  CastReaderTests
//
//  中国/全球双线路并存的回归合同。默认值、优先级、进程冻结、端点矩阵和
//  控制面失败回退都在这里锁死。旧已发布二进制的历史合同由服务端
//  兼容；新版客户端只有 global / cn 两条冻结线路，CN QuickRead 使用该线路的
//  独立备案入口。
//

import XCTest
@testable import CastReader

final class ServiceRoutingTests: XCTestCase {
    private let standardKeys = [
        "appRegion.v1.storefrontCountryCode",
        "appRegion.v1.override",
        "serviceRouting.v1.override",
        "serviceRouting.v1.backendConfiguration",
        "tts_endpoints_v1",
        "tts_endpoints_v1_time",
        "quickread_base_v1",
    ]
    private var savedStandardValues: [String: Any] = [:]
    private var suiteName = ""
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        savedStandardValues = [:]
        for key in standardKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                savedStandardValues[key] = value
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
        suiteName = "ServiceRoutingTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        resetSnapshots()
        RoutingURLProtocol.handler = nil
        RoutingRedirectURLProtocol.reset()
    }

    override func tearDown() {
        RoutingURLProtocol.handler = nil
        RoutingRedirectURLProtocol.reset()
        suite.removePersistentDomain(forName: suiteName)
        for key in standardKeys {
            UserDefaults.standard.removeObject(forKey: key)
            if let value = savedStandardValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        resetSnapshots()
        super.tearDown()
    }

    // MARK: - 安全默认与优先级

    func testAuthoritativeChinaStorefrontDefaultsToGlobalGatewayUntilRollout() {
        let snapshot = ServiceRouting.resolve(
            defaults: suite,
            arguments: [],
            appRegion: .cn,
            isAppRegionAuthoritative: true
        )
        XCTAssertEqual(snapshot, .init(route: .globalGateway, provenance: .safeDefault))
    }

    func testTimezoneFallbackCanNeverEnableChinaGateway() {
        let snapshot = ServiceRouting.resolve(
            defaults: suite,
            arguments: [],
            appRegion: .cn,
            isAppRegionAuthoritative: false
        )
        XCTAssertEqual(snapshot.route, .globalGateway)
        XCTAssertEqual(snapshot.provenance, .safeDefault)
    }

    func testValidBackendChinaRouteOnlyAppliesToAuthoritativeChinaRegion() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try saveBackendRecord(.chinaGateway, now: now, validFor: 7 * 24 * 3600, in: suite)

        let china = ServiceRouting.resolve(
            defaults: suite,
            arguments: [],
            now: now,
            appRegion: .cn,
            isAppRegionAuthoritative: true
        )
        XCTAssertEqual(china, .init(route: .chinaGateway, provenance: .backend))

        for region in [AppRegion.global] {
            let outsideChina = ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: region,
                isAppRegionAuthoritative: true
            )
            XCTAssertEqual(outsideChina.route, .globalGateway)
            XCTAssertEqual(outsideChina.provenance, .safeDefault)
        }
    }

    func testExpiredOrCorruptBackendConfigurationFallsBackToGlobal() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try saveBackendRecord(.chinaGateway, now: now, validFor: -1, in: suite)
        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: .cn,
                isAppRegionAuthoritative: true
            ).route,
            .globalGateway
        )

        suite.set(Data("not-json".utf8), forKey: ServiceRouting.backendConfigurationDefaultsKey)
        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: .cn,
                isAppRegionAuthoritative: true
            ).route,
            .globalGateway
        )
    }

    func testSevenDayBackendCacheStillAppliesOnNextDayColdLaunch() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try saveBackendRecord(
            .chinaGateway,
            now: fetchedAt,
            validFor: 7 * 24 * 3600,
            in: suite
        )
        let nextDay = fetchedAt.addingTimeInterval(24 * 3600)
        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: nextDay,
                appRegion: .cn,
                isAppRegionAuthoritative: true
            ),
            .init(route: .chinaGateway, provenance: .backend)
        )
    }

    func testCachedChinaRouteIsRevalidatedOnTheFirstLaunchAfterBuildUpgrade() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try saveBackendRecord(
            .chinaGateway,
            now: now,
            validFor: 7 * 24 * 3600,
            in: suite,
            minimumBuild: 39,
            maximumBuild: 39
        )

        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: .cn,
                isAppRegionAuthoritative: true,
                buildNumber: 39
            ).route,
            .chinaGateway
        )
        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: .cn,
                isAppRegionAuthoritative: true,
                buildNumber: 40
            ),
            .init(route: .globalGateway, provenance: .safeDefault),
            "a cached test-build rollout must not leak into an upgraded build"
        )
    }

    func testPriorityIsLaunchArgumentThenLocalOverrideThenBackendThenGlobal() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try saveBackendRecord(.chinaGateway, now: now, validFor: 3600, in: suite)
        suite.set(ServiceRoute.globalGateway.rawValue, forKey: ServiceRouting.overrideDefaultsKey)

        let local = ServiceRouting.resolve(
            defaults: suite,
            arguments: [],
            now: now,
            appRegion: .cn,
            isAppRegionAuthoritative: true,
            allowLocalOverride: true
        )
        XCTAssertEqual(local, .init(route: .globalGateway, provenance: .localOverride))

        let launch = ServiceRouting.resolve(
            defaults: suite,
            arguments: ["app", "-CastReaderServiceRoute", "cn"],
            now: now,
            appRegion: .cn,
            isAppRegionAuthoritative: true
        )
        XCTAssertEqual(launch, .init(route: .chinaGateway, provenance: .launchArgument))
    }

    func testExplicitProductRegionCouplesAccountRouteWhileAutomaticModeClearsOverride() {
        XCTAssertEqual(
            ServiceRouting.accountRouteOverride(for: .cn),
            .chinaGateway
        )
        XCTAssertEqual(
            ServiceRouting.accountRouteOverride(for: .global),
            .globalGateway
        )
        XCTAssertNil(ServiceRouting.accountRouteOverride(for: nil))
    }

    func testAppStoreUpgradeIgnoresPersistedTestFlightChinaOverride() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        suite.set(ServiceRoute.chinaGateway.rawValue, forKey: ServiceRouting.overrideDefaultsKey)
        try saveBackendRecord(.globalGateway, now: now, validFor: 3600, in: suite)

        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: .cn,
                isAppRegionAuthoritative: true,
                allowLocalOverride: false
            ),
            .init(route: .globalGateway, provenance: .backend),
            "an App Store upgrade must use valid backend config, not the persisted TestFlight switch"
        )

        suite.removeObject(forKey: ServiceRouting.backendConfigurationDefaultsKey)
        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: .cn,
                isAppRegionAuthoritative: true,
                allowLocalOverride: false
            ),
            .init(route: .globalGateway, provenance: .safeDefault),
            "without valid backend config, production must fall back to the global gateway"
        )

        ServiceRouting.discardDisallowedLocalOverride(
            defaults: suite,
            allowLocalOverride: false
        )
        XCTAssertNil(suite.object(forKey: ServiceRouting.overrideDefaultsKey))
    }

    func testAppStoreUpgradeCannotTurnNonChinaStorefrontIntoChinaViaPersistedRegion() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        suite.set(AppRegion.cn.rawValue, forKey: AppRegion.overrideDefaultsKey)
        suite.set("USA", forKey: "appRegion.v1.storefrontCountryCode")
        try saveBackendRecord(.chinaGateway, now: now, validFor: 3600, in: suite)

        let region = AppRegion.resolve(
            defaults: suite,
            arguments: [],
            timeZoneIdentifier: "Asia/Shanghai",
            allowLocalOverride: false
        )
        XCTAssertEqual(
            region,
            .init(region: .global, isAuthoritative: true, provenance: .storefront),
            "production must ignore a TestFlight region override and trust the non-CHN storefront"
        )
        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: region.region,
                isAppRegionAuthoritative: region.isAuthoritative,
                buildNumber: 39,
                allowLocalOverride: false
            ),
            .init(route: .globalGateway, provenance: .safeDefault),
            "a residual region value must not make the backend CN rollout eligible"
        )

        AppRegion.discardDisallowedOverride(defaults: suite, allowLocalOverride: false)
        XCTAssertNil(suite.object(forKey: AppRegion.overrideDefaultsKey))
    }

    func testPersistedLocalOverridePolicyIsDistributionBoundNotAccountBound() {
        let appStoreReceipt = URL(fileURLWithPath: "/StoreKit/receipt")
        let sandboxReceipt = URL(fileURLWithPath: "/StoreKit/sandboxReceipt")

        XCTAssertTrue(
            ServiceRouting.localOverrideAllowed(
                isDebugBuild: true,
                isInternalDistributionBuild: false,
                appStoreReceiptURL: appStoreReceipt,
                arguments: []
            )
        )
        XCTAssertFalse(
            ServiceRouting.localOverrideAllowed(
                isDebugBuild: false,
                isInternalDistributionBuild: false,
                appStoreReceiptURL: sandboxReceipt,
                arguments: []
            ),
            "App Review can have a sandbox receipt; the receipt alone cannot authorize switches"
        )
        XCTAssertFalse(
            ServiceRouting.localOverrideAllowed(
                isDebugBuild: false,
                isInternalDistributionBuild: false,
                appStoreReceiptURL: appStoreReceipt,
                arguments: [ServiceRouting.allowLocalOverrideLaunchArgument]
            ),
            "a process argument cannot turn a production archive into an internal build"
        )
        XCTAssertFalse(
            ServiceRouting.localOverrideAllowed(
                isDebugBuild: false,
                isInternalDistributionBuild: true,
                appStoreReceiptURL: appStoreReceipt,
                arguments: []
            ),
            "the signed internal flag still requires a sandbox distribution"
        )
        XCTAssertTrue(
            ServiceRouting.localOverrideAllowed(
                isDebugBuild: false,
                isInternalDistributionBuild: true,
                appStoreReceiptURL: sandboxReceipt,
                arguments: []
            ),
            "only an explicitly signed internal sandbox build exposes persisted switches"
        )
        XCTAssertFalse(
            ServiceRouting.localOverrideAllowed(
                isDebugBuild: false,
                isInternalDistributionBuild: true,
                appStoreReceiptURL: nil,
                arguments: []
            ),
            "unknown production distributions fail closed"
        )

        XCTAssertTrue(DistributionTestingPolicy.internalDistributionControlsEnabled(true))
        XCTAssertTrue(DistributionTestingPolicy.internalDistributionControlsEnabled("YES"))
        XCTAssertFalse(DistributionTestingPolicy.internalDistributionControlsEnabled("$(UNSET_BUILD_SETTING)"))
        XCTAssertFalse(DistributionTestingPolicy.internalDistributionControlsEnabled(nil))

        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: ["app", "-CastReaderServiceRoute", "cn"],
                appRegion: .global,
                isAppRegionAuthoritative: true,
                allowLocalOverride: false
            ),
            .init(route: .chinaGateway, provenance: .launchArgument),
            "the explicit non-persisted route argument remains available to automation"
        )
        XCTAssertEqual(
            AppRegion.resolve(
                defaults: suite,
                arguments: ["app", "-CastReaderRegion", "cn"],
                timeZoneIdentifier: "America/Los_Angeles",
                allowLocalOverride: false
            ),
            .init(region: .cn, isAuthoritative: true, provenance: .launchArgument),
            "the explicit non-persisted region argument remains available to automation"
        )
    }

    func testAppLaunchBootstrapsRouteBeforeCreatingVisitorIdentityOrMainUI() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSourceURL = repositoryRoot.appendingPathComponent("CastReader/CastReaderApp.swift")
        guard FileManager.default.fileExists(atPath: appSourceURL.path) else {
            throw XCTSkip("startup-order source contract requires the repository checkout")
        }
        let source = try String(contentsOf: appSourceURL, encoding: .utf8)
        XCTAssertFalse(
            source.contains("struct CastReaderApp: App {\n    @UIApplicationDelegateAdaptor(CastReaderAppDelegate.self) private var appDelegate\n    @StateObject private var visitorService"),
            "the App value itself must not construct VisitorService before async bootstrap"
        )
        XCTAssertTrue(source.contains("let region = await AppRegion.prepareForCurrentProcess()"))
        XCTAssertTrue(source.contains("await ServiceRouting.bootstrapForCurrentProcess("))
        XCTAssertTrue(source.contains("async let computeProbe = ComputeRouting.probeFirstPartyGateways"))
        XCTAssertTrue(source.contains("await ComputeRouting.bootstrapForCurrentProcess("))
        XCTAssertTrue(source.contains("if startup.isReady {\n                    RouteReadyRoot()"))
        XCTAssertTrue(source.contains("@StateObject private var visitorService = VisitorService.shared"))

        let bootstrap = try XCTUnwrap(
            source.range(of: "_ = await ServiceRouting.bootstrapForCurrentProcess(")?.lowerBound
        )
        let endpointFreeze = try XCTUnwrap(
            source.range(of: "_ = TTSEndpoint.freezeForCurrentProcess()")?.lowerBound
        )
        let computeFreeze = try XCTUnwrap(
            source.range(of: "_ = await ComputeRouting.bootstrapForCurrentProcess(")?.lowerBound
        )
        let serviceStart = try XCTUnwrap(
            source.range(of: "ProductAnalytics.shared.startAppSession")?.lowerBound
        )
        let ready = try XCTUnwrap(source.range(of: "isReady = true")?.lowerBound)
        XCTAssertLessThan(bootstrap, endpointFreeze)
        XCTAssertLessThan(bootstrap, computeFreeze)
        XCTAssertLessThan(computeFreeze, endpointFreeze)
        XCTAssertLessThan(endpointFreeze, serviceStart)
        XCTAssertLessThan(serviceStart, ready)
    }

    func testMalformedNonemptyOverrideAndLaunchArgumentFailClosed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try saveBackendRecord(.chinaGateway, now: now, validFor: 3600, in: suite)
        suite.set("unexpected", forKey: ServiceRouting.overrideDefaultsKey)

        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                now: now,
                appRegion: .cn,
                isAppRegionAuthoritative: true,
                allowLocalOverride: true
            ),
            .init(route: .globalGateway, provenance: .safeDefault)
        )
        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: ["app", "-CastReaderServiceRoute", "invalid"],
                now: now,
                appRegion: .cn,
                isAppRegionAuthoritative: true
            ),
            .init(route: .globalGateway, provenance: .safeDefault)
        )
    }

    func testLegacyRawValueMigratesOnlyFromLocalPersistence() throws {
        XCTAssertNil(ServiceRoute(rawValue: "legacy"), "server/launch values must be strict")
        XCTAssertEqual(ServiceRoute.fromPersistedRawValue("legacy"), .globalGateway)

        suite.set("legacy", forKey: ServiceRouting.overrideDefaultsKey)
        ServiceRouting.migratePersistedAliases(defaults: suite, allowLocalOverride: true)
        XCTAssertEqual(
            suite.string(forKey: ServiceRouting.overrideDefaultsKey),
            ServiceRoute.globalGateway.rawValue
        )
        XCTAssertEqual(
            ServiceRouting.resolve(
                defaults: suite,
                arguments: [],
                appRegion: .cn,
                isAppRegionAuthoritative: true,
                allowLocalOverride: true
            ),
            .init(route: .globalGateway, provenance: .localOverride)
        )
        XCTAssertNil(
            ServiceRouting.launchArgumentRoute(["app", "-CastReaderServiceRoute", "legacy"]),
            "the local migration alias must never become a public launch/server value"
        )

        let current = ServiceRouting.BackendCacheRecord(
            route: .globalGateway,
            minimumBuild: nil,
            maximumBuild: nil,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoded = try JSONEncoder().encode(current)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: #""route":"global""#, with: #""route":"legacy""#)
        suite.set(Data(json.utf8), forKey: ServiceRouting.backendConfigurationDefaultsKey)
        XCTAssertEqual(ServiceRouting.cachedBackendRecord(defaults: suite)?.route, .globalGateway)
        ServiceRouting.migratePersistedAliases(defaults: suite, allowLocalOverride: true)
        let migratedData = try XCTUnwrap(
            suite.data(forKey: ServiceRouting.backendConfigurationDefaultsKey)
        )
        XCTAssertFalse(String(decoding: migratedData, as: UTF8.self).contains(#""route":"legacy""#))
    }

    // MARK: - 进程冻结

    func testChangingAppOrBackendSettingNeverChangesCurrentProcess() throws {
        UserDefaults.standard.set("CHN", forKey: "appRegion.v1.storefrontCountryCode")
        try saveBackendRecord(
            .chinaGateway,
            now: Date(),
            validFor: 7 * 24 * 3600,
            in: .standard
        )
        resetSnapshots()
        XCTAssertEqual(ServiceRouting.current, .chinaGateway)

        ServiceRouting.overrideRoute = .globalGateway
        XCTAssertEqual(ServiceRouting.current, .chinaGateway, "当前进程不得切线")
        XCTAssertEqual(ServiceRouting.nextLaunchSnapshot.route, .globalGateway)
        XCTAssertEqual(ServiceRouting.nextLaunchSnapshot.provenance, .localOverride)
    }

    func testAppRegionChangeDoesNotChangeFrozenServiceRoute() {
        UserDefaults.standard.set("USA", forKey: "appRegion.v1.storefrontCountryCode")
        ServiceRouting.overrideRoute = .globalGateway
        resetSnapshots()
        XCTAssertEqual(ServiceRouting.current, .globalGateway)

        AppRegion.overrideRegion = .cn
        XCTAssertEqual(AppRegion.current, .cn)
        XCTAssertEqual(ServiceRouting.current, .globalGateway)
    }

    func testRetiredUpstreamCachesCannotChangeNewGatewayEndpoints() async {
        ServiceRouting.overrideRoute = .globalGateway
        resetSnapshots()
        _ = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "America/Los_Angeles",
            arguments: [],
            simCountryCodes: [],
            precomputedProbe: .init(
                china: .unavailable,
                global: .init(isReachable: true, latency: 0.01),
                country: .init(countryCode: "US")
            )
        )

        UserDefaults.standard.set(
            ["cn_url": "https://cn-a.example", "us_url": "https://us-a.example"],
            forKey: "tts_endpoints_v1"
        )
        let frozenTTSBase = TTSEndpoint.primaryBase()
        XCTAssertTrue(
            ["https://api.castreader.ai", "https://api.castreader.cn"].contains(frozenTTSBase)
        )
        UserDefaults.standard.set(
            ["cn_url": "https://cn-b.example", "us_url": "https://us-b.example"],
            forKey: "tts_endpoints_v1"
        )
        XCTAssertEqual(TTSEndpoint.primaryBase(), frozenTTSBase)

        UserDefaults.standard.set("https://qr-a.example", forKey: "quickread_base_v1")
        XCTAssertEqual(QuickReadEndpoint.base(), "https://api.castreader.ai")
        UserDefaults.standard.set("https://qr-b.example", forKey: "quickread_base_v1")
        XCTAssertEqual(QuickReadEndpoint.base(), "https://api.castreader.ai")
    }

    // MARK: - 独立计算线路

    func testComputeRouteUsesAuthoritativeNetworkCountryBeforeSIMAndTimeZone() {
        let chinaNetwork = ComputeRouting.resolve(
            timeZoneIdentifier: "America/Los_Angeles",
            networkCountry: .init(countryCode: "CN"),
            simCountryCodes: ["US"]
        )
        XCTAssertEqual(chinaNetwork.primary, .chinaGateway)
        XCTAssertEqual(chinaNetwork.provenance, .networkCountry)

        let overseasNetwork = ComputeRouting.resolve(
            timeZoneIdentifier: "Asia/Shanghai",
            networkCountry: .init(countryCode: "US"),
            simCountryCodes: ["CN"]
        )
        XCTAssertEqual(overseasNetwork.primary, .globalGateway)
        XCTAssertEqual(overseasNetwork.provenance, .networkCountry)
    }

    func testComputeRouteUsesSIMBeforeTimeZoneAndMixedSIMFailsGlobal() {
        let mainlandSIM = ComputeRouting.resolve(
            timeZoneIdentifier: "America/Los_Angeles",
            simCountryCodes: ["cn"]
        )
        XCTAssertEqual(mainlandSIM.primary, .chinaGateway)
        XCTAssertEqual(mainlandSIM.provenance, .simCountry)

        let overseasSIM = ComputeRouting.resolve(
            timeZoneIdentifier: "Asia/Shanghai",
            simCountryCodes: ["US"]
        )
        XCTAssertEqual(overseasSIM.primary, .globalGateway)
        XCTAssertEqual(overseasSIM.provenance, .simCountry)

        let mixedSIM = ComputeRouting.resolve(
            timeZoneIdentifier: "Asia/Shanghai",
            simCountryCodes: ["CN", "US"]
        )
        XCTAssertEqual(mixedSIM.primary, .globalGateway)
        XCTAssertEqual(mixedSIM.provenance, .simCountry)
    }

    func testComputeRouteDebugOverridePrecedesEveryLocationSignal() {
        #if DEBUG
        let overridden = ComputeRouting.resolve(
            timeZoneIdentifier: "Asia/Shanghai",
            networkCountry: .init(countryCode: "CN"),
            simCountryCodes: ["CN"],
            arguments: ["CastReader", "-CastReaderComputeRoute", "global"]
        )
        XCTAssertEqual(overridden.primary, .globalGateway)
        XCTAssertEqual(overridden.provenance, .debugOverride)
        #else
        XCTAssertNil(
            ComputeRouting.debugOverrideRoute(
                ["CastReader", "-CastReaderComputeRoute", "cn"]
            )
        )
        #endif
    }

    func testComputeRouteMainlandTimezoneAliasesExcludeNearbyRegions() {
        for identifier in [
            "Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing",
            "Asia/Harbin", "Asia/Kashgar", "PRC",
        ] {
            XCTAssertEqual(
                ComputeRouting.resolve(
                    timeZoneIdentifier: identifier
                ).primary,
                .chinaGateway,
                identifier
            )
        }

        for identifier in ["Asia/Hong_Kong", "Asia/Macau", "Asia/Taipei"] {
            XCTAssertEqual(
                ComputeRouting.resolve(
                    timeZoneIdentifier: identifier
                ).primary,
                .globalGateway,
                identifier
            )
        }
    }

    func testComputeProbeHasSharedHardDeadline() async {
        let startedAt = Date()
        let result = await ComputeRouting.probeFirstPartyGateways(timeout: 0.25) {
            route, _ in
            if route == .chinaGateway {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return .init(endpoint: .unavailable, country: nil)
                }
            }
            return .init(
                endpoint: .init(isReachable: true, latency: 0.01),
                country: route == .globalGateway ? .init(countryCode: "US") : nil
            )
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
        XCTAssertFalse(result.china.isReachable)
        XCTAssertTrue(result.global.isReachable)
        XCTAssertEqual(result.country?.countryCode, "US")
    }

    func testComputeRouteFreezesForEntireColdLaunch() async {
        let unavailable = ComputeRouting.NetworkProbe(
            china: .unavailable,
            global: .unavailable,
            country: nil
        )
        let first = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "Asia/Shanghai",
            arguments: [],
            simCountryCodes: [],
            precomputedProbe: unavailable
        )
        let laterConflictingSignal = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "America/Los_Angeles",
            arguments: [],
            simCountryCodes: ["US"],
            precomputedProbe: .init(
                china: .unavailable,
                global: .init(isReachable: true, latency: 0.01),
                country: .init(countryCode: "US")
            )
        )

        XCTAssertEqual(first.primary, .chinaGateway)
        XCTAssertEqual(laterConflictingSignal, first)
    }

    func testAnonymousTTSNeverResendsPayloadAcrossComputeRoutes() async {
        let unavailable = ComputeRouting.NetworkProbe(
            china: .unavailable,
            global: .unavailable,
            country: nil
        )
        _ = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "Asia/Shanghai",
            arguments: [],
            simCountryCodes: [],
            precomputedProbe: unavailable
        )

        var requestedHosts: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedHosts.append(request.url?.host ?? "")
            let status = 503
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"temporarily unavailable"}"#.utf8))
        }
        let routingSession = makeRoutingSession()
        let service = APIService(
            session: routingSession,
            ttsSessions: [
                .chinaGateway: routingSession,
                .globalGateway: routingSession,
            ]
        )

        do {
            _ = try await service.generateTTS(text: "hello", language: "en")
            XCTFail("a failed CN TTS payload must not be resent globally")
        } catch APIError.httpError(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requestedHosts, ["api.castreader.cn"])
    }

    func testAnonymousTTSDoesNotFallbackForRateLimitOrAuthContractFailure() async {
        for status in [401, 422, 429, 500] {
            resetSnapshots()
            let unavailable = ComputeRouting.NetworkProbe(
                china: .unavailable,
                global: .unavailable,
                country: nil
            )
            _ = await ComputeRouting.bootstrapForCurrentProcess(
                timeZoneIdentifier: "Asia/Shanghai",
                arguments: [],
                simCountryCodes: [],
                precomputedProbe: unavailable
            )
            var requestedHosts: [String] = []
            RoutingURLProtocol.handler = { request in
                requestedHosts.append(request.url?.host ?? "")
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error":"rejected"}"#.utf8))
            }
            let routingSession = makeRoutingSession()
            let service = APIService(
                session: routingSession,
                ttsSessions: [
                    .chinaGateway: routingSession,
                    .globalGateway: routingSession,
                ]
            )

            do {
                _ = try await service.generateTTS(text: "hello", language: "en")
                XCTFail("HTTP \(status) must not cross compute ingress")
            } catch APIError.httpError(let observed) {
                XCTAssertEqual(observed, status)
            } catch {
                XCTFail("unexpected error for HTTP \(status): \(error)")
            }
            XCTAssertEqual(requestedHosts, ["api.castreader.cn"])
        }
    }

    func testDisabledCloneVoiceFallsBackToAnonymousFrozenComputeTTS() async throws {
        XCTAssertFalse(Constants.Features.voiceCloningEnabled)
        _ = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "Asia/Shanghai",
            arguments: [],
            simCountryCodes: [],
            precomputedProbe: .init(
                china: .init(isReachable: true, latency: 0.01),
                global: .init(isReachable: true, latency: 0.02),
                country: .init(countryCode: "CN")
            )
        )

        var requestCount = 0
        RoutingURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.host, "api.castreader.cn")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Auth-Provider"))
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let voice = try XCTUnwrap(object["voice"] as? String)
            XCTAssertFalse(voice.hasPrefix("vc_"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"audio":"","timestamps":[]}"#.utf8))
        }
        let routingSession = makeRoutingSession()
        let service = APIService(
            session: routingSession,
            ttsSessions: [
                .chinaGateway: routingSession,
                .globalGateway: routingSession,
            ]
        )

        _ = try await service.generateTTS(
            text: "hello",
            voice: "vc_disabled_clone",
            language: "en"
        )

        XCTAssertEqual(requestCount, 1)
    }

    func testExplicitCredentialSessionsNeverPersistOrSendCookies() async throws {
        let configuration = OwnedAPIURLSession.explicitCredentialConfiguration(
            requestTimeout: 5,
            resourceTimeout: 5
        )
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        configuration.protocolClasses = [RoutingURLProtocol.self]

        var observedCookies: [String?] = []
        var requestCount = 0
        RoutingURLProtocol.handler = { request in
            requestCount += 1
            observedCookies.append(request.value(forHTTPHeaderField: "Cookie"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: requestCount == 1
                    ? ["Set-Cookie": "route_identity=must-not-persist; Path=/; Secure"]
                    : nil
            )!
            return (response, Data())
        }
        let session = OwnedAPIURLSession.make(
            configuration: configuration,
            route: .globalGateway
        )
        defer { session.invalidateAndCancel() }

        _ = try await session.data(from: URL(string: "https://api.castreader.ai/first")!)
        _ = try await session.data(from: URL(string: "https://api.castreader.ai/second")!)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(observedCookies.count, 2)
        XCTAssertNil(observedCookies[0])
        XCTAssertNil(observedCookies[1])
    }

    // MARK: - 完整端点合同

    func testGlobalRouteSendsEveryOwnedBusinessAPIThroughGlobalGateway() async {
        UserDefaults.standard.set("CHN", forKey: "appRegion.v1.storefrontCountryCode")
        ServiceRouting.overrideRoute = .globalGateway
        resetSnapshots()
        _ = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "America/Los_Angeles",
            arguments: [],
            simCountryCodes: [],
            precomputedProbe: .init(
                china: .unavailable,
                global: .init(isReachable: true, latency: 0.01),
                country: .init(countryCode: "US")
            )
        )

        XCTAssertEqual(Constants.API.baseURL, "https://api.castreader.ai")
        XCTAssertEqual(Constants.API.readerServiceURL, "https://api.castreader.ai")
        XCTAssertEqual(Constants.API.documents, "https://api.castreader.ai/api/mobile/documents")
        XCTAssertEqual(Constants.API.sts, "https://api.castreader.ai/api/mobile/upload/sts")
        XCTAssertEqual(Constants.API.asyncUpload, "https://api.castreader.ai/api/mobile/upload/notify")
        XCTAssertEqual(Constants.API.ttsCatalog, "https://api.castreader.ai/api/tts/catalog?contract=tts-voice-catalog-v1")

        XCTAssertEqual(Constants.API.webURL, "https://api.castreader.ai")
        XCTAssertEqual(Constants.API.proStatus, "https://api.castreader.ai/api/pro/status")
        XCTAssertEqual(Constants.API.mobileProStatusV2, "https://api.castreader.ai/api/mobile/pro/status/v2")
        XCTAssertEqual(Constants.API.proVerifyApple, "https://api.castreader.ai/api/pro/verify-apple")
        XCTAssertEqual(Constants.API.authSocialSignIn, "https://api.castreader.ai/api/auth/sign-in/social")
        XCTAssertEqual(Constants.API.analyticsEvents, "https://api.castreader.ai/api/events")
        XCTAssertEqual(Constants.API.emailOTPBaseURL, "https://api.castreader.ai")

        XCTAssertEqual(TTSEndpoint.primaryBase(isMainlandChina: true), "https://api.castreader.cn")
        XCTAssertNil(TTSEndpoint.fallbackBase(isMainlandChina: true))
        XCTAssertEqual(TTSEndpoint.primaryBase(isMainlandChina: false), "https://api.castreader.ai")
        XCTAssertNil(TTSEndpoint.fallbackBase(isMainlandChina: false))

        XCTAssertEqual(QuickReadEndpoint.base(), "https://api.castreader.ai")
        XCTAssertEqual(QuickReadEndpoint.planURL, "https://api.castreader.ai/api/quickread/extract-plan")
        XCTAssertEqual(Constants.API.quickReadBaseURL, "https://api.castreader.ai")
        XCTAssertEqual(Constants.API.quickReadPlan, QuickReadEndpoint.planURL)
        XCTAssertEqual(URL(string: Constants.API.termsURL)?.host, "castreader.com")
    }

    func testChinaRouteUsesFiledGeneralGatewayAndDedicatedQuickReadIngress() async {
        UserDefaults.standard.set("CHN", forKey: "appRegion.v1.storefrontCountryCode")
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()
        _ = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "Asia/Shanghai",
            arguments: [],
            simCountryCodes: [],
            precomputedProbe: .init(
                china: .init(isReachable: true, latency: 0.01),
                global: .init(isReachable: true, latency: 0.02),
                country: .init(countryCode: "CN")
            )
        )

        XCTAssertEqual(Constants.API.baseURL, "https://api.castreader.cn")
        XCTAssertEqual(Constants.API.documents, "https://api.castreader.cn/api/mobile/documents")
        XCTAssertEqual(Constants.API.sts, "https://api.castreader.cn/api/mobile/upload/sts")
        XCTAssertEqual(Constants.API.asyncUpload, "https://api.castreader.cn/api/mobile/upload/notify")
        XCTAssertEqual(Constants.API.tts, "https://api.castreader.cn/api/captioned_speech_partly")
        XCTAssertEqual(Constants.API.ttsCatalog, "https://api.castreader.cn/api/tts/catalog?contract=tts-voice-catalog-v1")
        XCTAssertEqual(Constants.API.webURL, "https://api.castreader.cn")
        XCTAssertEqual(Constants.API.proStatus, "https://api.castreader.cn/api/pro/status")
        XCTAssertEqual(Constants.API.proListenTrack, "https://api.castreader.cn/api/pro/listen-track")
        XCTAssertEqual(Constants.API.proVerifyApple, "https://api.castreader.cn/api/pro/verify-apple")
        XCTAssertEqual(Constants.API.authSocialSignIn, "https://api.castreader.cn/api/auth/sign-in/social")
        XCTAssertEqual(Constants.API.analyticsEvents, "https://api.castreader.cn/api/events")
        XCTAssertEqual(Constants.API.emailOTPBaseURL, "https://api.castreader.cn")

        XCTAssertEqual(TTSEndpoint.primaryBase(isMainlandChina: true), "https://api.castreader.cn")
        XCTAssertEqual(TTSEndpoint.primaryBase(isMainlandChina: false), "https://api.castreader.ai")
        XCTAssertNil(TTSEndpoint.fallbackBase(isMainlandChina: true))
        XCTAssertNil(TTSEndpoint.fallbackBase(isMainlandChina: false))

        XCTAssertEqual(QuickReadEndpoint.base(), "https://quickread.castreader.cn")
        XCTAssertEqual(Constants.API.quickReadBaseURL, "https://quickread.castreader.cn")
        XCTAssertEqual(Constants.API.quickReadPlan, QuickReadEndpoint.planURL)
        XCTAssertEqual(QuickReadEndpoint.planURL, "https://quickread.castreader.cn/api/quickread/extract-plan")
        XCTAssertEqual(QuickReadEndpoint.extractBlockURL, "https://quickread.castreader.cn/api/quickread/extract-block")
        XCTAssertEqual(QuickReadEndpoint.composeBlockURL, "https://quickread.castreader.cn/api/quickread/compose-block")
        XCTAssertEqual(QuickReadEndpoint.fastBlock0URL, "https://quickread.castreader.cn/api/quickread/fast-block0")

        // 法务与书架平台不是自有业务 API，不应被服务线路重写。
        XCTAssertEqual(URL(string: Constants.API.privacyURL)?.host, "castreader.com")
        XCTAssertEqual(
            AppRegion.cn.availableBoundLibraries,
            [.weread, .kindle, .googleBooks, .kobo, .oreilly]
        )
    }

    func testChinaOwnedRedirectPolicyAllowsOnlyFiledGateway() throws {
        let original = try XCTUnwrap(URL(string: "https://api.castreader.cn/api/pro/status"))
        let accepted = [
            "https://api.castreader.cn/api/pro/status?moved=1",
            "https://api.castreader.cn:443/api/pro/status",
        ]
        let rejected = [
            "http://api.castreader.cn/api/pro/status",
            "https://api.castreader.cn:8443/api/pro/status",
            "https://api.castreader.ai/api/pro/status",
            "https://castreader.ai/api/pro/status",
            "https://castreader.com/api/pro/status",
            "https://qr.castreader.ai/api/quickread/extract-plan",
            "https://quickread.castreader.ai/api/quickread/extract-plan",
            "https://api.castreader.cn.evil.example/api/pro/status",
            "https://cdn.example.com/api/pro/status",
        ]

        for rawURL in accepted {
            XCTAssertTrue(
                OwnedAPIRedirectPolicy.allowsRedirect(
                    route: .chinaGateway,
                    originalURL: original,
                    proposedURL: URL(string: rawURL)
                ),
                rawURL
            )
        }
        for rawURL in rejected {
            XCTAssertFalse(
                OwnedAPIRedirectPolicy.allowsRedirect(
                    route: .chinaGateway,
                    originalURL: original,
                    proposedURL: URL(string: rawURL)
                ),
                rawURL
            )
        }
        XCTAssertFalse(
            OwnedAPIRedirectPolicy.allowsRedirect(
                route: .chinaGateway,
                originalURL: original,
                proposedURL: nil
            )
        )
    }

    func testChinaQuickReadRedirectCannotCrossItsDedicatedIngress() throws {
        let original = try XCTUnwrap(
            URL(string: "https://quickread.castreader.cn/api/quickread/extract-plan")
        )
        XCTAssertTrue(
            OwnedAPIRedirectPolicy.allowsRedirect(
                route: .chinaGateway,
                originalURL: original,
                proposedURL: URL(string: "https://quickread.castreader.cn/api/quickread/extract-plan?retry=1")
            )
        )
        for target in [
            "https://api.castreader.cn/api/quickread/extract-plan",
            "https://api.castreader.ai/api/quickread/extract-plan",
            "https://quickread.castreader.ai/api/quickread/extract-plan",
            "https://qr.castreader.ai/api/quickread/extract-plan",
        ] {
            XCTAssertFalse(
                OwnedAPIRedirectPolicy.allowsRedirect(
                    route: .chinaGateway,
                    originalURL: original,
                    proposedURL: URL(string: target)
                ),
                target
            )
        }
    }

    func testGlobalOwnedRedirectPolicyAllowsOnlyGlobalGateway() throws {
        let original = try XCTUnwrap(URL(string: "https://api.castreader.ai/documents"))
        for rawURL in [
            "https://api.castreader.ai/documents?moved=1",
            "https://api.castreader.ai:443/documents",
        ] {
            XCTAssertTrue(
                OwnedAPIRedirectPolicy.allowsRedirect(
                    route: .globalGateway,
                    originalURL: original,
                    proposedURL: URL(string: rawURL)
                ),
                rawURL
            )
        }
        for rawURL in [
            "http://api.castreader.ai/documents",
            "https://api.castreader.ai:8443/documents",
            "https://api.castreader.cn/documents",
            "https://castreader.ai/documents",
            "https://castreader.com/documents",
            "https://qr.castreader.ai/documents",
            "https://api.castreader.ai.evil.example/documents",
        ] {
            XCTAssertFalse(
                OwnedAPIRedirectPolicy.allowsRedirect(
                    route: .globalGateway,
                    originalURL: original,
                    proposedURL: URL(string: rawURL)
                ),
                rawURL
            )
        }
    }

    func testThirdPartyClientsRemainOutsideOwnedGatewayPinning() throws {

        // A COS/OAuth/bookshelf request is not a CastReader-owned request. It
        // never receives route pinning even if the app itself is on the CN line.
        for thirdPartyOriginal in [
            "https://oauth2.googleapis.com/token",
            "https://bucket.cos.ap-shanghai.myqcloud.com/object",
            "https://weread.qq.com/web/bookList",
            "https://www.youtube.com/watch?v=test",
        ] {
            XCTAssertTrue(
                OwnedAPIRedirectPolicy.allowsRedirect(
                    route: .chinaGateway,
                    originalURL: URL(string: thirdPartyOriginal),
                    proposedURL: URL(string: "https://third-party-cdn.example/resource")
                ),
                thirdPartyOriginal
            )
        }
    }

    func testChinaResponseProvidedURLsRequireAnExplicitGatewayPathContract() throws {
        let responseURLs: [(String, String)] = [
            (
                "https://api.castreader.ai/api/tts/assets/voice-library/en/sample.mp3?version=2",
                "https://api.castreader.cn/api/tts/assets/voice-library/en/sample.mp3?version=2"
            ),
            (
                "https://quickread.castreader.cn/api/quickread/qrc_abcdefghijklmnopqrstuvwxyz123456/spec",
                "https://quickread.castreader.cn/api/quickread/qrc_abcdefghijklmnopqrstuvwxyz123456/spec"
            ),
        ]
        for (raw, expected) in responseURLs {
            let routed = try XCTUnwrap(
                OwnedAPIRedirectPolicy.routedResponseURL(
                    try XCTUnwrap(URL(string: raw)),
                    route: .chinaGateway
                )
            )
            XCTAssertEqual(routed.absoluteString, expected, raw)
        }

        for rawThirdPartyURL in [
            "https://cdn.localdeepseek.org/documents/book/content.md",
            "https://ai-reader-1323065328.cos.accelerate.myqcloud.com/documents/book/cover.jpg",
            "https://zqxgmqygirtpttnrvjpf.supabase.co/storage/v1/object/public/castreader-public/voice.mp3",
            "https://lh3.googleusercontent.com/account-avatar",
        ] {
            let thirdParty = try XCTUnwrap(URL(string: rawThirdPartyURL))
            XCTAssertEqual(
                OwnedAPIRedirectPolicy.routedResponseURL(
                    thirdParty,
                    route: .chinaGateway
                ),
                thirdParty,
                "R2/COS/Supabase/bookshelf assets must remain third-party traffic"
            )
        }

        let global = try XCTUnwrap(URL(string: responseURLs[0].0))
        XCTAssertEqual(
            OwnedAPIRedirectPolicy.routedResponseURL(
                global,
                route: .globalGateway
            ),
            global,
            "an exact global-gateway response URL remains byte-for-byte unchanged"
        )

        for invalidGlobalOwnedURL in [
            "http://api.castreader.ai/api/tts/assets/voice.mp3",
            "https://api.castreader.ai:8443/api/tts/assets/voice.mp3",
            "https://api.castreader.cn/api/tts/assets/voice.mp3",
            "https://castreader.ai/profile/avatar.png",
            "https://castreader.com/profile/avatar.png",
            "https://qr.castreader.ai/api/quickread/private/spec",
        ] {
            XCTAssertNil(
                OwnedAPIRedirectPolicy.routedResponseURL(
                    try XCTUnwrap(URL(string: invalidGlobalOwnedURL)),
                    route: .globalGateway
                ),
                invalidGlobalOwnedURL
            )
        }

        for unsupportedOwnedURL in [
            "https://api.castreader.ai/documents/book.md?token=abc",
            "https://api.castreader.ai/api/tts-legacy/voice.mp3",
            "http://api.castreader.ai/api/tts/assets/voice.mp3",
            "https://api.castreader.ai:8443/api/tts/assets/voice.mp3",
            "https://castreader.com/profile/avatar.png",
            "https://cdn.castreader.ai/covers/book.jpg",
            "https://qr.castreader.ai/api/quickread/private/spec",
        ] {
            XCTAssertNil(
                OwnedAPIRedirectPolicy.routedResponseURL(
                    try XCTUnwrap(URL(string: unsupportedOwnedURL)),
                    route: .chinaGateway
                ),
                unsupportedOwnedURL
            )
        }
        XCTAssertNil(
            OwnedAPIRedirectPolicy.routedResponseURL(
                try XCTUnwrap(URL(string: "https://user:secret@api.castreader.ai/private")),
                route: .chinaGateway
            )
        )
    }

    func testProtectedSTSUsesSelectedGatewayAndServerSessionForBothRoutes() async throws {
        let cases: [(ServiceRoute, String)] = [
            (.globalGateway, "https://api.castreader.ai/api/mobile/upload/sts"),
            (.chinaGateway, "https://api.castreader.cn/api/mobile/upload/sts"),
        ]

        for (route, expectedURL) in cases {
            ServiceRouting.overrideRoute = route
            resetSnapshots()
            let token = "cms_\(route.rawValue)_upload_session"
            let provider = RoutingMobileSessionProvider(currentToken: token)
            var requestCount = 0
            RoutingURLProtocol.handler = { request in
                requestCount += 1
                XCTAssertEqual(request.url?.absoluteString, expectedURL)
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer \(token)"
                )
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "session")
                XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
                XCTAssertNil(request.value(forHTTPHeaderField: "x-device-id"))
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (response, try Self.makeSTSSuccessData(prefix: route.rawValue))
            }

            let service = APIService(
                session: makeRoutingSession(),
                mobileSessionProvider: provider
            )
            let credentials = try await service.fetchSTSCredentials()

            XCTAssertEqual(credentials.accessKeyId, "\(route.rawValue)-access")
            XCTAssertEqual(credentials.prefix, "\(route.rawValue)/uploads/")
            XCTAssertEqual(requestCount, 1)
            let refreshCount = await provider.refreshCallCount()
            XCTAssertEqual(refreshCount, 0)
        }
    }

    func testProtectedSTSRejectsMissingOrLocalSessionBeforeNetwork() async {
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()

        for token in [String?.none, "cms_local_debug_fallback"] {
            let provider = RoutingMobileSessionProvider(currentToken: token)
            var didTouchNetwork = false
            RoutingURLProtocol.handler = { request in
                didTouchNetwork = true
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (response, Data())
            }
            let service = APIService(
                session: makeRoutingSession(),
                mobileSessionProvider: provider
            )

            do {
                _ = try await service.fetchSTSCredentials()
                XCTFail("a protected upload credential request must require a server cms_ session")
            } catch APIError.httpError(let status) {
                XCTAssertEqual(status, 401)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            XCTAssertFalse(didTouchNetwork)
            let refreshCount = await provider.refreshCallCount()
            XCTAssertEqual(refreshCount, 1)
        }
    }

    func testProtectedSTSRefreshesOnceOn401WithoutCrossHostOrLegacyFallback() async throws {
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()

        let provider = RoutingMobileSessionProvider(
            currentToken: "cms_expired_upload_session",
            refreshedToken: "cms_refreshed_upload_session"
        )
        var requestedURLs: [String] = []
        var authorizationValues: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            authorizationValues.append(
                request.value(forHTTPHeaderField: "Authorization") ?? ""
            )
            let status = requestedURLs.count == 1 ? 401 : 200
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            let data = status == 200
                ? try Self.makeSTSSuccessData(prefix: "cn")
                : Data(#"{"error":"expired"}"#.utf8)
            return (response, data)
        }
        let service = APIService(
            session: makeRoutingSession(),
            mobileSessionProvider: provider
        )

        _ = try await service.fetchSTSCredentials()

        let refreshCount = await provider.refreshCallCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(
            requestedURLs,
            Array(repeating: "https://api.castreader.cn/api/mobile/upload/sts", count: 2)
        )
        XCTAssertEqual(
            authorizationValues,
            ["Bearer cms_expired_upload_session", "Bearer cms_refreshed_upload_session"]
        )
        XCTAssertFalse(requestedURLs.contains { $0.hasSuffix("/sts") && !$0.contains("/api/mobile/upload/") })
        XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == "api.castreader.ai" })
    }

    func testProtectedDocumentsUseSelectedGatewayAndServerSessionForBothRoutes() async throws {
        for route in [ServiceRoute.globalGateway, .chinaGateway] {
            ServiceRouting.overrideRoute = route
            resetSnapshots()
            let token = "cms_\(route.rawValue)_documents_session"
            let provider = RoutingMobileSessionProvider(currentToken: token)
            var requestCount = 0
            RoutingURLProtocol.handler = { request in
                requestCount += 1
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "\(route.apiGatewayBaseURL)/api/mobile/documents?limit=7&offset=3"
                )
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer \(token)"
                )
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "session")
                XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
                XCTAssertNil(request.value(forHTTPHeaderField: "x-device-id"))
                XCTAssertNil(request.value(forHTTPHeaderField: "x-user-id"))
                XCTAssertNil(request.value(forHTTPHeaderField: "x-email"))
                XCTAssertNil(
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "user_id" })
                )
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                let data = Data(
                    "{\"success\":true,\"documents\":[{\"id\":\"doc-\(route.rawValue)\",\"name\":\"Owned document\"}],\"count\":1}".utf8
                )
                return (response, data)
            }

            let service = APIService(
                session: makeRoutingSession(),
                mobileSessionProvider: provider
            )
            let documents = try await service.fetchDocuments(limit: 7, offset: 3)
            let refreshCallCount = await provider.refreshCallCount()

            XCTAssertEqual(documents.map(\.id), ["doc-\(route.rawValue)"])
            XCTAssertEqual(requestCount, 1)
            XCTAssertEqual(refreshCallCount, 0)
        }
    }

    func testProtectedDocumentsRejectMissingOrLocalSessionBeforeNetwork() async {
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()

        for token in [String?.none, "cms_local_debug_fallback"] {
            let provider = RoutingMobileSessionProvider(currentToken: token)
            var didTouchNetwork = false
            RoutingURLProtocol.handler = { request in
                didTouchNetwork = true
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (response, Data())
            }
            let service = APIService(
                session: makeRoutingSession(),
                mobileSessionProvider: provider
            )

            do {
                _ = try await service.fetchDocuments()
                XCTFail("a protected document list must require a server cms_ session")
            } catch APIError.httpError(let status) {
                XCTAssertEqual(status, 401)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            let refreshCallCount = await provider.refreshCallCount()
            XCTAssertFalse(didTouchNetwork)
            XCTAssertEqual(refreshCallCount, 1)
        }
    }

    func testProtectedDocumentsRefreshOnceWithoutCrossHostOrLegacyFallback() async throws {
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()

        let provider = RoutingMobileSessionProvider(
            currentToken: "cms_expired_documents_session",
            refreshedToken: "cms_refreshed_documents_session"
        )
        var requestedURLs: [String] = []
        var authorizationValues: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            authorizationValues.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let status = requestedURLs.count == 1 ? 401 : 200
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            let data = status == 200
                ? Data(#"{"success":true,"documents":[],"count":0}"#.utf8)
                : Data(#"{"error":"expired"}"#.utf8)
            return (response, data)
        }
        let service = APIService(
            session: makeRoutingSession(),
            mobileSessionProvider: provider
        )

        _ = try await service.fetchDocuments(limit: 5, offset: 10)
        let refreshCallCount = await provider.refreshCallCount()

        let expectedURL = "https://api.castreader.cn/api/mobile/documents?limit=5&offset=10"
        XCTAssertEqual(refreshCallCount, 1)
        XCTAssertEqual(requestedURLs, Array(repeating: expectedURL, count: 2))
        XCTAssertEqual(
            authorizationValues,
            ["Bearer cms_expired_documents_session", "Bearer cms_refreshed_documents_session"]
        )
        XCTAssertFalse(requestedURLs.contains { $0.contains("/documents?user_id=") })
        XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == "api.castreader.ai" })
    }

    func testProtectedUploadNotifyUsesSelectedGatewaySessionAndSafeMultipart() async throws {
        for route in [ServiceRoute.globalGateway, .chinaGateway] {
            for fileExtension in ["pdf", "epub"] {
                ServiceRouting.overrideRoute = route
                resetSnapshots()
                let filename = "sample.\(fileExtension)"
                let filepath = "user/\(route.rawValue)/canonical-hash/550e8400-e29b-41d4-a716-446655440000/550e8400-e29b-41d4-a716-446655440001_\(filename)"
                let token = "cms_\(route.rawValue)_notify_session"
                let provider = RoutingMobileSessionProvider(currentToken: token)
                var requestCount = 0
                RoutingURLProtocol.handler = { request in
                    requestCount += 1
                    XCTAssertEqual(
                        request.url?.absoluteString,
                        "\(route.apiGatewayBaseURL)/api/mobile/upload/notify"
                    )
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "Authorization"),
                        "Bearer \(token)"
                    )
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "X-Auth-Provider"),
                        "session"
                    )
                    XCTAssertTrue(
                        request.value(forHTTPHeaderField: "Content-Type")?
                            .hasPrefix("multipart/form-data; boundary=") == true
                    )
                    let body = String(
                        data: try XCTUnwrap(request.httpBody),
                        encoding: .utf8
                    ) ?? ""
                    XCTAssertTrue(body.contains("name=\"filename\"\r\n\r\n\(filename)"))
                    XCTAssertTrue(body.contains("name=\"filepath\"\r\n\r\n\(filepath)"))
                    XCTAssertTrue(body.contains("name=\"voice_id\""))
                    XCTAssertFalse(body.contains("name=\"user_id\""))
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-device-id"))
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-user-id"))
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!
                    return (response, Data(#"{"success":true,"message":"queued"}"#.utf8))
                }
                let service = APIService(
                    session: makeRoutingSession(),
                    mobileSessionProvider: provider
                )

                let result = try await service.notifyUpload(
                    filename: filename,
                    filepath: filepath
                )

                XCTAssertTrue(result.success)
                XCTAssertEqual(requestCount, 1)
                let refreshCount = await provider.refreshCallCount()
                XCTAssertEqual(refreshCount, 0)
            }
        }
    }

    func testProtectedUploadNotifyRejectsMissingSessionBeforeNetwork() async {
        ServiceRouting.overrideRoute = .globalGateway
        resetSnapshots()
        let provider = RoutingMobileSessionProvider(currentToken: nil)
        var didTouchNetwork = false
        RoutingURLProtocol.handler = { request in
            didTouchNetwork = true
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"success":true}"#.utf8))
        }
        let service = APIService(
            session: makeRoutingSession(),
            mobileSessionProvider: provider
        )

        do {
            _ = try await service.notifyUpload(
                filename: "sample.pdf",
                filepath: "user/global/hash/sts/object_sample.pdf"
            )
            XCTFail("upload notify must require a server cms_ session")
        } catch APIError.httpError(let status) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(didTouchNetwork)
        let refreshCount = await provider.refreshCallCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testProtectedUploadNotifyRefreshes401OnceWithoutLegacyFallback() async throws {
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()
        let provider = RoutingMobileSessionProvider(
            currentToken: "cms_expired_notify_session",
            refreshedToken: "cms_refreshed_notify_session"
        )
        var requestedURLs: [String] = []
        var authorizationValues: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            authorizationValues.append(
                request.value(forHTTPHeaderField: "Authorization") ?? ""
            )
            let status = requestedURLs.count == 1 ? 401 : 200
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            let data = status == 200
                ? Data(#"{"success":true}"#.utf8)
                : Data(#"{"error":"expired"}"#.utf8)
            return (response, data)
        }
        let service = APIService(
            session: makeRoutingSession(),
            mobileSessionProvider: provider
        )

        _ = try await service.notifyUpload(
            filename: "sample.epub",
            filepath: "user/cn/hash/sts/object_sample.epub"
        )

        let refreshCount = await provider.refreshCallCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(
            requestedURLs,
            Array(
                repeating: "https://api.castreader.cn/api/mobile/upload/notify",
                count: 2
            )
        )
        XCTAssertEqual(
            authorizationValues,
            ["Bearer cms_expired_notify_session", "Bearer cms_refreshed_notify_session"]
        )
        XCTAssertFalse(requestedURLs.contains { $0.contains("async-md-upload-by-url") })
        XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == "api.castreader.ai" })
    }

    func testComputeTicketExchangeHasExactContractAndIsBoundToCurrentCMS() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = RoutingMobileSessionProvider(currentToken: "cms_account_A")
        var exchangeAuthorization: [String] = []
        RoutingURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.castreader.ai/api/mobile-auth/compute-session"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            exchangeAuthorization.append(authorization)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                    as? [String: String]
            )
            XCTAssertEqual(object, ["audience": "quickread", "targetRoute": "cn"])
            let suffix = authorization.hasSuffix("account_B") ? "B" : "A"
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                    "Cache-Control": "no-store",
                ]
            )!
            return (
                response,
                Self.makeComputeTicketData(
                    token: "cmc_ticket_\(suffix)",
                    expiresAt: now.addingTimeInterval(15 * 60)
                )
            )
        }
        let store = QuickReadComputeSessionStore(
            accountRoute: .globalGateway,
            targetRoute: .chinaGateway,
            session: makeRoutingSession(),
            mobileSessionProvider: provider,
            now: { now }
        )

        let firstATicket = try await store.ticket(forceRefresh: false)
        let cachedATicket = try await store.ticket(forceRefresh: false)
        XCTAssertEqual(firstATicket.token, "cmc_ticket_A")
        XCTAssertEqual(cachedATicket.token, "cmc_ticket_A")
        XCTAssertEqual(exchangeAuthorization, ["Bearer cms_account_A"])

        await provider.setCurrentToken(nil)
        do {
            _ = try await store.ticket(forceRefresh: false)
            XCTFail("a signed-out account must never reuse the previous account's cmc ticket")
        } catch QuickReadError.httpError(let status) {
            XCTAssertEqual(status, 401)
        }
        XCTAssertEqual(exchangeAuthorization, ["Bearer cms_account_A"])

        await provider.setCurrentToken("cms_account_B")
        let bTicket = try await store.ticket(forceRefresh: false)
        XCTAssertEqual(bTicket.token, "cmc_ticket_B")
        XCTAssertEqual(
            exchangeAuthorization,
            ["Bearer cms_account_A", "Bearer cms_account_B"]
        )
    }

    func testComputeTicketExchangeIsSymmetricFromChinaAccountToGlobal() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = RoutingMobileSessionProvider(currentToken: "cms_cn_account")
        var observedBody: [String: String] = [:]
        RoutingURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.castreader.cn/api/mobile-auth/compute-session"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cms_cn_account")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "session")
            observedBody = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                    as? [String: String]
            )
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Self.makeComputeTicketData(
                    token: "cmc_global_quickread",
                    expiresAt: now.addingTimeInterval(15 * 60),
                    targetRoute: .globalGateway
                )
            )
        }
        let store = QuickReadComputeSessionStore(
            accountRoute: .chinaGateway,
            targetRoute: .globalGateway,
            session: makeRoutingSession(),
            mobileSessionProvider: provider,
            now: { now }
        )

        let ticket = try await store.ticket(forceRefresh: false)

        XCTAssertEqual(ticket.token, "cmc_global_quickread")
        XCTAssertEqual(observedBody, ["audience": "quickread", "targetRoute": "global"])
    }

    func testComputeTicketRotatesSourceBindingAfterCMSRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = RoutingMobileSessionProvider(
            currentToken: "cms_expired_A",
            refreshedToken: "cms_refreshed_B"
        )
        var authorizations: [String] = []
        RoutingURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            authorizations.append(authorization)
            let isRefreshed = authorization == "Bearer cms_refreshed_B"
            let status = isRefreshed ? 200 : 401
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                isRefreshed
                    ? Self.makeComputeTicketData(
                        token: "cmc_for_B",
                        expiresAt: now.addingTimeInterval(15 * 60)
                    )
                    : Data(#"{"error":"expired"}"#.utf8)
            )
        }
        let store = QuickReadComputeSessionStore(
            accountRoute: .globalGateway,
            targetRoute: .chinaGateway,
            session: makeRoutingSession(),
            mobileSessionProvider: provider,
            now: { now }
        )

        let refreshedTicket = try await store.ticket(forceRefresh: false)
        let cachedRefreshedTicket = try await store.ticket(forceRefresh: false)
        XCTAssertEqual(refreshedTicket.token, "cmc_for_B")
        XCTAssertEqual(cachedRefreshedTicket.token, "cmc_for_B")
        XCTAssertEqual(authorizations, ["Bearer cms_expired_A", "Bearer cms_refreshed_B"])
        let refreshCount = await provider.refreshCallCount()
        let rejected = await provider.rejectedSessionTokens()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testGlobalAccountChinaComputeUsesOnlyCMCTicketAndFreezesContinuationTransport() async throws {
        let provider = RoutingMobileSessionProvider(currentToken: "cms_global_account")
        let computeProvider = RoutingComputeSessionProvider(token: "cmc_cn_quickread")
        var requestedURLs: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            XCTAssertEqual(request.url?.host, "quickread.castreader.cn")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer cmc_cn_quickread"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Auth-Provider"),
                "compute-session"
            )
            XCTAssertFalse(
                request.value(forHTTPHeaderField: "Authorization")?.contains("cms_") == true
            )
            let isPlan = request.url?.path == "/api/quickread/extract-plan"
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "Content-Type": isPlan ? "text/event-stream" : "application/json",
                ]
            )!
            return (
                response,
                isPlan
                    ? Self.makeQuickReadSSEData(id: "cn-compute")
                    : Self.makeQuickReadSectionData(id: "cn-continuation")
            )
        }
        let session = makeRoutingSession()
        let service = QuickReadService(
            session: session,
            mobileSessionProvider: provider,
            computeSession: session,
            computeSessionProvider: computeProvider,
            accountRoute: .globalGateway,
            computeRoute: .chinaGateway
        )

        let done = try await service.extractPlan(
            Self.makeExtractPlanRequest(),
            onStage: { _ in },
            onBlock0: { _ in }
        )
        let section = try await service.extractBlock(
            jobId: try XCTUnwrap(done.job_id),
            blockIdx: 1
        )

        XCTAssertEqual(section.id, "cn-continuation")
        XCTAssertEqual(
            requestedURLs,
            [
                "https://quickread.castreader.cn/api/quickread/extract-plan",
                "https://quickread.castreader.cn/api/quickread/extract-block",
            ]
        )
        let refreshCount = await provider.refreshCallCount()
        let rejected = await provider.rejectedSessionTokens()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testChinaAccountGlobalComputeUsesOnlyCMCTicketAndFreezesContinuationTransport() async throws {
        let provider = RoutingMobileSessionProvider(currentToken: "cms_cn_account")
        let computeProvider = RoutingComputeSessionProvider(token: "cmc_global_quickread")
        var requestedURLs: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            XCTAssertEqual(request.url?.host, "api.castreader.ai")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer cmc_global_quickread"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Auth-Provider"),
                "compute-session"
            )
            let isPlan = request.url?.path == "/api/quickread/extract-plan"
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "Content-Type": isPlan ? "text/event-stream" : "application/json",
                ]
            )!
            return (
                response,
                isPlan
                    ? Self.makeQuickReadSSEData(id: "global-compute")
                    : Self.makeQuickReadSectionData(id: "global-continuation")
            )
        }
        let session = makeRoutingSession()
        let service = QuickReadService(
            session: session,
            mobileSessionProvider: provider,
            computeSession: session,
            computeSessionProvider: computeProvider,
            accountRoute: .chinaGateway,
            computeRoute: .globalGateway
        )

        let done = try await service.extractPlan(
            Self.makeExtractPlanRequest(id: "cn-account-global-compute"),
            onStage: { _ in },
            onBlock0: { _ in }
        )
        let section = try await service.extractBlock(
            jobId: try XCTUnwrap(done.job_id),
            blockIdx: 1
        )

        XCTAssertEqual(section.id, "global-continuation")
        XCTAssertEqual(
            requestedURLs,
            [
                "https://api.castreader.ai/api/quickread/extract-plan",
                "https://api.castreader.ai/api/quickread/extract-block",
            ]
        )
        let refreshCount = await provider.refreshCallCount()
        let rejected = await provider.rejectedSessionTokens()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testBlock0BindsCrossRouteJobBeforeImmediateContinuationCallback() async throws {
        let provider = RoutingMobileSessionProvider(currentToken: "cms_global_account")
        let computeProvider = RoutingComputeSessionProvider(token: "cmc_cn_race")
        var continuationHosts: [String] = []
        RoutingURLProtocol.handler = { request in
            let isPlan = request.url?.path == "/api/quickread/extract-plan"
            if !isPlan {
                continuationHosts.append(request.url?.host ?? "")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cmc_cn_race")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "compute-session")
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "Content-Type": isPlan ? "text/event-stream" : "application/json",
                ]
            )!
            return (
                response,
                isPlan
                    ? Self.makeQuickReadSSEData(id: "immediate")
                    : Self.makeQuickReadSectionData(id: "immediate-continuation")
            )
        }
        let session = makeRoutingSession()
        let service = QuickReadService(
            session: session,
            mobileSessionProvider: provider,
            computeSession: session,
            computeSessionProvider: computeProvider,
            accountRoute: .globalGateway,
            computeRoute: .chinaGateway
        )
        var continuationTask: Task<QuickreadSection, Error>?

        _ = try await service.extractPlan(
            Self.makeExtractPlanRequest(id: "immediate-continuation"),
            onStage: { _ in },
            onBlock0: { block in
                continuationTask = Task {
                    try await service.extractBlock(jobId: block.job_id, blockIdx: 1)
                }
            }
        )
        let task = try XCTUnwrap(continuationTask)
        let section = try await task.value

        XCTAssertEqual(section.id, "immediate-continuation")
        XCTAssertEqual(continuationHosts, ["quickread.castreader.cn"])
    }

    func testUnknownQuickReadJobTransportFailsClosedBeforeNetwork() async {
        var didTouchNetwork = false
        RoutingURLProtocol.handler = { request in
            didTouchNetwork = true
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Self.makeQuickReadSectionData(id: "forbidden"))
        }
        let service = QuickReadService(
            session: makeRoutingSession(),
            mobileSessionProvider: RoutingMobileSessionProvider(currentToken: "cms_account"),
            accountRoute: .globalGateway,
            computeRoute: .chinaGateway
        )

        do {
            _ = try await service.extractBlock(jobId: "unknown-job", blockIdx: 1)
            XCTFail("an unbound continuation must never guess an ingress")
        } catch QuickReadError.missingJobTransport {
            // Expected fail-closed boundary.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(didTouchNetwork)
    }

    func testComputePayloadFailureNeverCrossesToGlobalIngress() async {
        let provider = RoutingMobileSessionProvider(currentToken: "cms_must_stay_private")
        let computeProvider = RoutingComputeSessionProvider(token: "cmc_failed_cn_job")
        var requestedHosts: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedHosts.append(request.url?.host ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cmc_failed_cn_job")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"unavailable"}"#.utf8))
        }
        let session = makeRoutingSession()
        let service = QuickReadService(
            session: session,
            mobileSessionProvider: provider,
            computeSession: session,
            computeSessionProvider: computeProvider,
            accountRoute: .globalGateway,
            computeRoute: .chinaGateway
        )

        do {
            _ = try await service.extractPlan(
                Self.makeExtractPlanRequest(id: "no-cross-replay"),
                onStage: { _ in },
                onBlock0: { _ in }
            )
            XCTFail("CN payload failure must surface without sending the body globally")
        } catch QuickReadError.httpError(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requestedHosts, Array(repeating: "quickread.castreader.cn", count: 3))
        XCTAssertFalse(requestedHosts.contains("api.castreader.ai"))
        let rejected = await provider.rejectedSessionTokens()
        XCTAssertTrue(rejected.isEmpty)
    }

    func testComputeTicketPreflightFailureNeverSendsPayloadToAccountIngress() async {
        let provider = RoutingMobileSessionProvider(currentToken: "cms_global_account")
        let computeProvider = RoutingComputeSessionProvider(failure: .cannotConnect)
        var requestedHosts: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedHosts.append(request.url?.host ?? "")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Self.makeQuickReadSSEData(id: "forbidden"))
        }
        let session = makeRoutingSession()
        let service = QuickReadService(
            session: session,
            mobileSessionProvider: provider,
            computeSession: session,
            computeSessionProvider: computeProvider,
            accountRoute: .globalGateway,
            computeRoute: .chinaGateway
        )

        do {
            _ = try await service.extractPlan(
                Self.makeExtractPlanRequest(id: "preflight"),
                onStage: { _ in },
                onBlock0: { _ in }
            )
            XCTFail("ticket failure must fail closed before any正文 request")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertTrue(requestedHosts.isEmpty)
    }

    func testChinaProductComputeTicketFailureIsFailClosed() async {
        let provider = RoutingMobileSessionProvider(currentToken: "cms_staged_global_route")
        let computeProvider = RoutingComputeSessionProvider(failure: .cannotConnect)
        var didSendPayload = false
        RoutingURLProtocol.handler = { request in
            didSendPayload = true
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Self.makeQuickReadSSEData(id: "forbidden"))
        }
        let session = makeRoutingSession()
        let service = QuickReadService(
            session: session,
            mobileSessionProvider: provider,
            computeSession: session,
            computeSessionProvider: computeProvider,
            accountRoute: .globalGateway,
            computeRoute: .chinaGateway
        )

        do {
            _ = try await service.extractPlan(
                Self.makeExtractPlanRequest(id: "china-product"),
                onStage: { _ in },
                onBlock0: { _ in }
            )
            XCTFail("China product must fail closed when its CN compute ticket is unavailable")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertFalse(didSendPayload)
    }

    func testComputeTicketAuthAndContractFailuresNeverFallback() async {
        for status in [401, 422] {
            let provider = RoutingMobileSessionProvider(currentToken: "cms_global_\(status)")
            let computeProvider = RoutingComputeSessionProvider(failure: .http(status))
            var didSendPayload = false
            RoutingURLProtocol.handler = { request in
                didSendPayload = true
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }
            let session = makeRoutingSession()
            let service = QuickReadService(
                session: session,
                mobileSessionProvider: provider,
                computeSession: session,
                computeSessionProvider: computeProvider,
                accountRoute: .globalGateway,
                computeRoute: .chinaGateway
            )

            do {
                _ = try await service.extractPlan(
                    Self.makeExtractPlanRequest(id: "fail-closed-\(status)"),
                    onStage: { _ in },
                    onBlock0: { _ in }
                )
                XCTFail("ticket HTTP \(status) must fail closed")
            } catch QuickReadError.httpError(let observed) {
                XCTAssertEqual(observed, status)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            XCTAssertFalse(didSendPayload)
        }
    }

    func testComputeTicket401RefreshesOnlyCMCAndNeverRejectsGlobalCMS() async throws {
        let provider = RoutingMobileSessionProvider(currentToken: "cms_global_survives")
        let computeProvider = RoutingComputeSessionProvider(
            token: "cmc_expired",
            refreshedToken: "cmc_refreshed"
        )
        var authorizations: [String] = []
        RoutingURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            authorizations.append(authorization)
            XCTAssertEqual(request.url?.host, "quickread.castreader.cn")
            let refreshed = authorization == "Bearer cmc_refreshed"
            let status = refreshed ? 200 : 401
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: [
                    "Content-Type": refreshed ? "text/event-stream" : "application/json",
                ]
            )!
            return (
                response,
                refreshed
                    ? Self.makeQuickReadSSEData(id: "refreshed-cmc")
                    : Data(#"{"error":"COMPUTE_SESSION_EXPIRED"}"#.utf8)
            )
        }
        let session = makeRoutingSession()
        let service = QuickReadService(
            session: session,
            mobileSessionProvider: provider,
            computeSession: session,
            computeSessionProvider: computeProvider,
            accountRoute: .globalGateway,
            computeRoute: .chinaGateway
        )

        _ = try await service.extractPlan(
            Self.makeExtractPlanRequest(id: "cmc-refresh"),
            onStage: { _ in },
            onBlock0: { _ in }
        )

        XCTAssertEqual(authorizations, ["Bearer cmc_expired", "Bearer cmc_refreshed"])
        let invalidations = await computeProvider.invalidations()
        let refreshCount = await provider.refreshCallCount()
        let rejected = await provider.rejectedSessionTokens()
        let survivingCMS = await provider.sessionToken()
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(survivingCMS, "cms_global_survives")
    }

    func testComputeTicketGeneric401DoesNotRemintOrRejectAccountCMS() async {
        let provider = RoutingMobileSessionProvider(currentToken: "cms_global_survives_scope_error")
        let computeProvider = RoutingComputeSessionProvider(
            token: "cmc_scope_mismatch",
            refreshedToken: "cmc_must_not_be_minted"
        )
        var authorizations: [String] = []
        RoutingURLProtocol.handler = { request in
            authorizations.append(
                request.value(forHTTPHeaderField: "Authorization") ?? ""
            )
            XCTAssertEqual(request.url?.host, "quickread.castreader.cn")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"code":"COMPUTE_SESSION_SCOPE_MISMATCH"}"#.utf8)
            )
        }
        let session = makeRoutingSession()
        let service = QuickReadService(
            session: session,
            mobileSessionProvider: provider,
            computeSession: session,
            computeSessionProvider: computeProvider,
            accountRoute: .globalGateway,
            computeRoute: .chinaGateway
        )

        do {
            _ = try await service.extractPlan(
                Self.makeExtractPlanRequest(id: "cmc-scope-mismatch"),
                onStage: { _ in },
                onBlock0: { _ in }
            )
            XCTFail("a non-expiration 401 must fail without minting another compute ticket")
        } catch QuickReadError.httpError(let status) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(authorizations, ["Bearer cmc_scope_mismatch"])
        let invalidations = await computeProvider.invalidations()
        let forceRefreshValues = await computeProvider.requestedForceRefreshValues()
        let refreshCount = await provider.refreshCallCount()
        let rejected = await provider.rejectedSessionTokens()
        let survivingCMS = await provider.sessionToken()
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(forceRefreshValues, [false, false])
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(survivingCMS, "cms_global_survives_scope_error")
    }

    func testQuickReadContinuationUsesSelectedGatewayAndOnlyServerSessionIdentity() async throws {
        let cases: [(ServiceRoute, String)] = [
            (.globalGateway, "https://api.castreader.ai/api/quickread/extract-block"),
            (.chinaGateway, "https://quickread.castreader.cn/api/quickread/extract-block"),
        ]

        for (route, expectedURL) in cases {
            ServiceRouting.overrideRoute = route
            resetSnapshots()
            let token = "cms_\(route.rawValue)_quickread_session"
            let provider = RoutingMobileSessionProvider(currentToken: token)
            var requestCount = 0
            RoutingURLProtocol.handler = { request in
                requestCount += 1
                XCTAssertEqual(request.url?.absoluteString, expectedURL)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer \(token)"
                )
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "session")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "x-quickread-continuation"),
                    "true"
                )
                for forbiddenHeader in [
                    "x-api-key", "x-device-id", "x-user-id", "x-user-email", "x-is-pro",
                ] {
                    XCTAssertNil(
                        request.value(forHTTPHeaderField: forbiddenHeader),
                        forbiddenHeader
                    )
                }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (response, Self.makeQuickReadSectionData(id: route.rawValue))
            }

            let service = QuickReadService(
                session: makeRoutingSession(),
                mobileSessionProvider: provider
            )
            await service.bindCurrentTransportForTesting(jobID: "job-test")
            let section = try await service.extractBlock(jobId: "job-test", blockIdx: 1)

            XCTAssertEqual(section.id, route.rawValue)
            XCTAssertEqual(requestCount, 1)
            let refreshCount = await provider.refreshCallCount()
            XCTAssertEqual(refreshCount, 0)
        }
    }

    func testQuickReadRejectsMissingOrLocalSessionBeforeNetwork() async {
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()

        for token in [String?.none, "cms_local_debug_fallback"] {
            let provider = RoutingMobileSessionProvider(currentToken: token)
            var didTouchNetwork = false
            RoutingURLProtocol.handler = { request in
                didTouchNetwork = true
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (response, Self.makeQuickReadSectionData(id: "unexpected"))
            }
            let service = QuickReadService(
                session: makeRoutingSession(),
                mobileSessionProvider: provider
            )
            await service.bindCurrentTransportForTesting(jobID: "job-test")

            do {
                _ = try await service.extractBlock(jobId: "job-test", blockIdx: 1)
                XCTFail("QuickRead must require a server cms_ session")
            } catch QuickReadError.httpError(let status) {
                XCTAssertEqual(status, 401)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            XCTAssertFalse(didTouchNetwork)
            let refreshCount = await provider.refreshCallCount()
            XCTAssertEqual(refreshCount, 1)
        }
    }

    func testQuickReadSSERefreshesOnceOn401WithoutCrossHostFallback() async throws {
        for route in [ServiceRoute.globalGateway, .chinaGateway] {
            ServiceRouting.overrideRoute = route
            resetSnapshots()
            let provider = RoutingMobileSessionProvider(
                currentToken: "cms_expired_\(route.rawValue)_sse",
                refreshedToken: "cms_refreshed_\(route.rawValue)_sse"
            )
            var requestedURLs: [String] = []
            var authorizationValues: [String] = []
            RoutingURLProtocol.handler = { request in
                requestedURLs.append(request.url?.absoluteString ?? "")
                authorizationValues.append(
                    request.value(forHTTPHeaderField: "Authorization") ?? ""
                )
                XCTAssertNil(request.value(forHTTPHeaderField: "x-quickread-continuation"))
                let status = requestedURLs.count == 1 ? 401 : 200
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": status == 200
                            ? "text/event-stream"
                            : "application/json",
                    ]
                )!
                return (
                    response,
                    status == 200
                        ? Self.makeQuickReadSSEData(id: route.rawValue)
                        : Data(#"{"error":"expired"}"#.utf8)
                )
            }
            let service = QuickReadService(
                session: makeRoutingSession(),
                mobileSessionProvider: provider
            )
            let request = ExtractPlanRequest(
                source_url: "castreader://test/\(route.rawValue)",
                title: "Route auth refresh",
                lang: "en",
                depth: "standard",
                text: "A paragraph.",
                fullText: "A paragraph.",
                paragraphs: [QuickreadParagraphDTO(text: "A paragraph.", type: "paragraph")]
            )

            let done = try await service.extractPlan(
                request,
                onStage: { _ in },
                onBlock0: { _ in }
            )

            XCTAssertEqual(done.job_id, "job-\(route.rawValue)")
            let refreshCount = await provider.refreshCallCount()
            XCTAssertEqual(refreshCount, 1)
            XCTAssertEqual(
                requestedURLs,
                Array(
                    repeating: "\(route.quickReadBaseURL)/api/quickread/extract-plan",
                    count: 2
                )
            )
            XCTAssertEqual(
                authorizationValues,
                [
                    "Bearer cms_expired_\(route.rawValue)_sse",
                    "Bearer cms_refreshed_\(route.rawValue)_sse",
                ]
            )
            let otherHost = route == .globalGateway ? "api.castreader.cn" : "api.castreader.ai"
            XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == otherHost })
        }
    }

    func testQuickReadJSONRequestsRefreshOnceOn401WithoutCrossHostFallback() async throws {
        for route in [ServiceRoute.globalGateway, .chinaGateway] {
            for operation in ["extract", "compose"] {
                ServiceRouting.overrideRoute = route
                resetSnapshots()
                let provider = RoutingMobileSessionProvider(
                    currentToken: "cms_expired_\(route.rawValue)_\(operation)",
                    refreshedToken: "cms_refreshed_\(route.rawValue)_\(operation)"
                )
                let path = operation == "extract"
                    ? "/api/quickread/extract-block"
                    : "/api/quickread/compose-block"
                var requestedURLs: [String] = []
                var authorizationValues: [String] = []
                RoutingURLProtocol.handler = { request in
                    requestedURLs.append(request.url?.absoluteString ?? "")
                    authorizationValues.append(
                        request.value(forHTTPHeaderField: "Authorization") ?? ""
                    )
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "x-quickread-continuation"),
                        "true"
                    )
                    let status = requestedURLs.count == 1 ? 401 : 200
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: status, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (
                        response,
                        status == 200
                            ? Self.makeQuickReadSectionData(id: "\(route.rawValue)-\(operation)")
                            : Data(#"{"error":"expired"}"#.utf8)
                    )
                }
                let service = QuickReadService(
                    session: makeRoutingSession(),
                    mobileSessionProvider: provider
                )
                await service.bindCurrentTransportForTesting(jobID: "job-test")

                let section: QuickreadSection
                if operation == "extract" {
                    section = try await service.extractBlock(jobId: "job-test", blockIdx: 1)
                } else {
                    section = try await service.composeBlock(
                        jobId: "job-test",
                        blockIdx: 1,
                        timestamps: [ComposeTimestamp(word: "word", start: 0, end: 0.2)],
                        duration: 0.2
                    )
                }

                XCTAssertEqual(section.id, "\(route.rawValue)-\(operation)")
                let refreshCount = await provider.refreshCallCount()
                XCTAssertEqual(refreshCount, 1)
                XCTAssertEqual(
                    requestedURLs,
                    Array(repeating: "\(route.quickReadBaseURL)\(path)", count: 2)
                )
                XCTAssertEqual(
                    authorizationValues,
                    [
                        "Bearer cms_expired_\(route.rawValue)_\(operation)",
                        "Bearer cms_refreshed_\(route.rawValue)_\(operation)",
                    ]
                )
                let otherHost = route == .globalGateway
                    ? "api.castreader.cn"
                    : "api.castreader.ai"
                XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == otherHost })
            }
        }
    }

    func testQuickReadFastPathRefreshesOnceOn401WithoutCrossHostFallback() async throws {
        for route in [ServiceRoute.globalGateway, .chinaGateway] {
            ServiceRouting.overrideRoute = route
            resetSnapshots()
            let provider = RoutingMobileSessionProvider(
                currentToken: "cms_expired_\(route.rawValue)_fast",
                refreshedToken: "cms_refreshed_\(route.rawValue)_fast"
            )
            var requestedURLs: [String] = []
            var authorizationValues: [String] = []
            RoutingURLProtocol.handler = { request in
                requestedURLs.append(request.url?.absoluteString ?? "")
                authorizationValues.append(
                    request.value(forHTTPHeaderField: "Authorization") ?? ""
                )
                XCTAssertNil(request.value(forHTTPHeaderField: "x-quickread-continuation"))
                let status = requestedURLs.count == 1 ? 401 : 200
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (
                    response,
                    status == 200
                        ? Self.makeQuickReadFastData(id: route.rawValue)
                        : Data(#"{"error":"expired"}"#.utf8)
                )
            }
            let service = QuickReadService(
                session: makeRoutingSession(),
                mobileSessionProvider: provider
            )

            let section = try await service.fastBlock0(
                title: "Fast",
                openingParas: ["A paragraph."],
                lang: "en",
                depth: "standard",
                prevSummary: nil,
                contentType: nil
            )

            XCTAssertEqual(section.id, "fast-0")
            XCTAssertEqual(section.text, "fast-\(route.rawValue)")
            let refreshCount = await provider.refreshCallCount()
            XCTAssertEqual(refreshCount, 1)
            XCTAssertEqual(
                requestedURLs,
                Array(
                    repeating: "\(route.quickReadBaseURL)/api/quickread/fast-block0",
                    count: 2
                )
            )
            XCTAssertEqual(
                authorizationValues,
                [
                    "Bearer cms_expired_\(route.rawValue)_fast",
                    "Bearer cms_refreshed_\(route.rawValue)_fast",
                ]
            )
            let otherHost = route == .globalGateway ? "api.castreader.cn" : "api.castreader.ai"
            XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == otherHost })
        }
    }

    func testQuickReadStopsAfterOneRefreshWhenGatewayStillReturns401() async {
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()
        let provider = RoutingMobileSessionProvider(
            currentToken: "cms_expired_quickread_once",
            refreshedToken: "cms_rejected_quickread_once"
        )
        var requestedURLs: [String] = []
        var authorizationValues: [String] = []
        RoutingURLProtocol.handler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            authorizationValues.append(
                request.value(forHTTPHeaderField: "Authorization") ?? ""
            )
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let service = QuickReadService(
            session: makeRoutingSession(),
            mobileSessionProvider: provider
        )
        await service.bindCurrentTransportForTesting(jobID: "job-test")

        do {
            _ = try await service.extractBlock(jobId: "job-test", blockIdx: 1)
            XCTFail("a second 401 must stop after the single session refresh")
        } catch QuickReadError.httpError(let status) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let refreshCount = await provider.refreshCallCount()
        let rejectedTokens = await provider.rejectedSessionTokens()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(rejectedTokens, [String?("cms_rejected_quickread_once")])
        XCTAssertEqual(
            requestedURLs,
            Array(
                repeating: "https://quickread.castreader.cn/api/quickread/extract-block",
                count: 2
            )
        )
        XCTAssertEqual(
            authorizationValues,
            [
                "Bearer cms_expired_quickread_once",
                "Bearer cms_rejected_quickread_once",
            ]
        )
        XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == "api.castreader.ai" })
        XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == "api.castreader.cn" })
        XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == "quickread.castreader.ai" })
        XCTAssertFalse(requestedURLs.contains { URL(string: $0)?.host == "qr.castreader.ai" })
    }

    func testQuickReadTransportFailureDoesNotRejectAuthenticatedSession() async {
        ServiceRouting.overrideRoute = .chinaGateway
        resetSnapshots()
        let provider = RoutingMobileSessionProvider(
            currentToken: "cms_network_failure_must_survive"
        )
        RoutingURLProtocol.handler = { _ in
            throw URLError(.cannotFindHost)
        }
        let service = QuickReadService(
            session: makeRoutingSession(),
            mobileSessionProvider: provider
        )
        await service.bindCurrentTransportForTesting(jobID: "job-test")

        do {
            _ = try await service.extractBlock(jobId: "job-test", blockIdx: 1)
            XCTFail("DNS failure must surface to the caller")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }

        let refreshCount = await provider.refreshCallCount()
        let rejectedTokens = await provider.rejectedSessionTokens()
        let survivingToken = await provider.sessionToken()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(rejectedTokens.isEmpty)
        XCTAssertEqual(survivingToken, "cms_network_failure_must_survive")
    }

    func testPersistedProfileRequiresRouteLocalCMSSessionToRestore() throws {
        let account = UserAccount(
            id: "phone-user",
            email: nil,
            name: "138****8000",
            pictureURL: nil,
            provider: "phone",
            backendUserId: "canonical-phone-user",
            maskedPhone: "138****8000"
        )
        let data = try JSONEncoder().encode(account)

        XCTAssertNil(
            AuthService.restorableAccount(
                from: data,
                persistedSessionToken: nil
            )
        )
        XCTAssertEqual(
            AuthService.restorableAccount(
                from: data,
                persistedSessionToken: "cms_route_local_session"
            ),
            account
        )
        XCTAssertNil(
            AuthService.restorableAccount(
                from: Data("corrupt".utf8),
                persistedSessionToken: "cms_route_local_session"
            )
        )
    }

    func testRejectedSessionCannotSignOutNewerAccountBoundary() {
        XCTAssertTrue(
            AuthService.shouldCloseAccountForRejectedSession(
                currentToken: "cms_account_a",
                rejectedToken: "cms_account_a"
            )
        )
        XCTAssertFalse(
            AuthService.shouldCloseAccountForRejectedSession(
                currentToken: "cms_account_b",
                rejectedToken: "cms_account_a"
            )
        )
        XCTAssertTrue(
            AuthService.shouldCloseAccountForRejectedSession(
                currentToken: nil,
                rejectedToken: nil
            )
        )
        XCTAssertFalse(
            AuthService.shouldCloseAccountForRejectedSession(
                currentToken: "cms_account_b",
                rejectedToken: nil
            )
        )
    }

    func testAppleAuthorizationCodeIsSentOnlyToSelectedGatewaySessionExchange() async throws {
        for route in [ServiceRoute.globalGateway, .chinaGateway] {
            let keys = MobileSessionStore.storageKeys(for: route)
            let saved = [
                keys.session: KeychainStore.get(keys.session),
                keys.provider: KeychainStore.get(keys.provider),
                keys.identityToken: KeychainStore.get(keys.identityToken),
            ]
            defer {
                for (key, value) in saved {
                    if let value {
                        KeychainStore.set(value, for: key)
                    } else {
                        KeychainStore.delete(key)
                    }
                }
            }

            var capturedBody: [String: Any] = [:]
            RoutingURLProtocol.handler = { request in
                XCTAssertEqual(
                    request.url?.absoluteString,
                    "\(route.webBaseURL)/api/mobile-auth/session"
                )
                capturedBody = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                        as? [String: Any]
                )
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                let data = Data(
                    #"{"code":0,"data":{"token":"cms_apple_exchange_test","userId":"user-test"}}"#.utf8
                )
                return (response, data)
            }
            let store = MobileSessionStore(
                session: makeRoutingSession(),
                route: route
            )
            let exchange = try await store.exchange(
                provider: "apple",
                idToken: "apple-identity-token",
                authorizationCode: "apple-one-time-code",
                deviceId: "device-test"
            )

            XCTAssertEqual(capturedBody["provider"] as? String, "apple")
            XCTAssertEqual(capturedBody["idToken"] as? String, "apple-identity-token")
            XCTAssertEqual(capturedBody["authorizationCode"] as? String, "apple-one-time-code")
            XCTAssertEqual(capturedBody["deviceId"] as? String, "device-test")
            XCTAssertEqual(exchange.token, "cms_apple_exchange_test")
            XCTAssertEqual(exchange.canonicalUserId, "user-test")
            XCTAssertEqual(KeychainStore.get(keys.identityToken), "apple-identity-token")
            XCTAssertNotEqual(KeychainStore.get(keys.identityToken), "apple-one-time-code")
        }
    }

    func testAuthorizationCodeCannotLeakFromNonAppleSessionExchange() async throws {
        let route = ServiceRoute.globalGateway
        let keys = MobileSessionStore.storageKeys(for: route)
        let saved = [
            keys.session: KeychainStore.get(keys.session),
            keys.provider: KeychainStore.get(keys.provider),
            keys.identityToken: KeychainStore.get(keys.identityToken),
        ]
        defer {
            for (key, value) in saved {
                if let value {
                    KeychainStore.set(value, for: key)
                } else {
                    KeychainStore.delete(key)
                }
            }
        }
        RoutingURLProtocol.handler = { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                    as? [String: Any]
            )
            XCTAssertNil(body["authorizationCode"])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (
                response,
                Data(#"{"code":0,"data":{"token":"cms_google_exchange_test","userId":"user-google-test"}}"#.utf8)
            )
        }
        let store = MobileSessionStore(session: makeRoutingSession(), route: route)
        _ = try await store.exchange(
            provider: "google",
            idToken: "google-id-token",
            authorizationCode: "must-never-leak",
            deviceId: "device-test"
        )
    }

    func testSessionExchangeRejectsMissingCanonicalUserIdBeforePersistingToken() async {
        let route = ServiceRoute.globalGateway
        let keys = MobileSessionStore.storageKeys(for: route)
        let saved = [
            keys.session: KeychainStore.get(keys.session),
            keys.provider: KeychainStore.get(keys.provider),
            keys.identityToken: KeychainStore.get(keys.identityToken),
        ]
        defer {
            for (key, value) in saved {
                if let value {
                    KeychainStore.set(value, for: key)
                } else {
                    KeychainStore.delete(key)
                }
            }
        }
        _ = MobileSessionStore.detachLocalSession(for: route)
        RoutingURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (
                response,
                Data(#"{"code":0,"data":{"token":"cms_missing_user_id"}}"#.utf8)
            )
        }

        let store = MobileSessionStore(session: makeRoutingSession(), route: route)
        do {
            _ = try await store.exchange(
                provider: "apple",
                idToken: "apple-id-token",
                deviceId: "device-test"
            )
            XCTFail("A session without canonical userId must fail closed")
        } catch {}

        let persistedToken = await store.sessionToken()
        XCTAssertNil(persistedToken)
        XCTAssertNil(KeychainStore.get(keys.provider))
        XCTAssertNil(KeychainStore.get(keys.identityToken))
    }

    func testCanonicalUserIdNormalizationRejectsEmptyAndOversizedValues() {
        XCTAssertEqual(
            MobileSessionStore.normalizedCanonicalUserId("  canonical-user  "),
            "canonical-user"
        )
        XCTAssertNil(MobileSessionStore.normalizedCanonicalUserId(nil))
        XCTAssertNil(MobileSessionStore.normalizedCanonicalUserId(" \n "))
        XCTAssertNil(
            MobileSessionStore.normalizedCanonicalUserId(
                String(repeating: "a", count: 513)
            )
        )
    }

    func testDetachedLogoutRevocationCannotEraseNewAccountSession() async throws {
        let route = ServiceRoute.globalGateway
        let keys = MobileSessionStore.storageKeys(for: route)
        let saved = [
            keys.session: KeychainStore.get(keys.session),
            keys.provider: KeychainStore.get(keys.provider),
            keys.identityToken: KeychainStore.get(keys.identityToken),
        ]
        defer {
            for (key, value) in saved {
                if let value {
                    KeychainStore.set(value, for: key)
                } else {
                    KeychainStore.delete(key)
                }
            }
        }

        var revokedAuthorization: String?
        RoutingURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            revokedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let store = MobileSessionStore(session: makeRoutingSession(), route: route)
        _ = try await store.adoptExternalSession(
            token: "cms_old_account_session",
            provider: "phone"
        )

        let detached = MobileSessionStore.detachLocalSession(for: route)
        XCTAssertEqual(detached, "cms_old_account_session")
        let tokenAfterDetach = await store.sessionToken()
        XCTAssertNil(tokenAfterDetach)

        _ = try await store.adoptExternalSession(
            token: "cms_new_account_session",
            provider: "phone"
        )
        await store.revokeDetachedSession(detached)

        XCTAssertEqual(revokedAuthorization, "Bearer cms_old_account_session")
        let currentToken = await store.sessionToken()
        XCTAssertEqual(
            currentToken,
            "cms_new_account_session",
            "account A's delayed remote logout must never clear account B's local bearer"
        )
    }

    func testInFlightAccountARefreshCannotOverwriteAccountBAfterSignOut() async throws {
        let route = ServiceRoute.globalGateway
        let keys = MobileSessionStore.storageKeys(for: route)
        let saved = [
            keys.session: KeychainStore.get(keys.session),
            keys.provider: KeychainStore.get(keys.provider),
            keys.identityToken: KeychainStore.get(keys.identityToken),
        ]
        defer {
            for (key, value) in saved {
                if let value {
                    KeychainStore.set(value, for: key)
                } else {
                    KeychainStore.delete(key)
                }
            }
        }

        _ = MobileSessionStore.detachLocalSession(for: route)
        XCTAssertTrue(KeychainStore.set("cms_account_a", for: keys.session))
        XCTAssertTrue(KeychainStore.set("google", for: keys.provider))
        XCTAssertTrue(KeychainStore.set("account-a-id-token", for: keys.identityToken))

        let requestStarted = expectation(description: "account A refresh started")
        let allowOldResponse = DispatchSemaphore(value: 0)
        defer { allowOldResponse.signal() }
        RoutingURLProtocol.handler = { request in
            requestStarted.fulfill()
            _ = allowOldResponse.wait(timeout: .now() + 5)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data(#"{"code":0,"data":{"token":"cms_account_a_refreshed","userId":"account-a"}}"#.utf8)
            )
        }

        let store = MobileSessionStore(session: makeRoutingSession(), route: route)
        let accountARefresh = Task { await store.refreshSession() }
        await fulfillment(of: [requestStarted], timeout: 2)

        _ = MobileSessionStore.detachLocalSession(for: route)
        _ = try await store.adoptExternalSession(
            token: "cms_account_b",
            provider: "phone"
        )
        allowOldResponse.signal()

        let staleRefreshResult = await accountARefresh.value
        let currentToken = await store.sessionToken()
        XCTAssertNil(staleRefreshResult)
        XCTAssertEqual(currentToken, "cms_account_b")
    }

    func testExternalPhoneSessionRejectsNonServerTokenWithoutPersistingIt() async {
        let route = ServiceRoute.chinaGateway
        let keys = MobileSessionStore.storageKeys(for: route)
        let saved = [
            keys.session: KeychainStore.get(keys.session),
            keys.provider: KeychainStore.get(keys.provider),
            keys.identityToken: KeychainStore.get(keys.identityToken),
        ]
        defer {
            for (key, value) in saved {
                if let value {
                    KeychainStore.set(value, for: key)
                } else {
                    KeychainStore.delete(key)
                }
            }
        }
        _ = MobileSessionStore.detachLocalSession(for: route)
        let store = MobileSessionStore(route: route)

        do {
            _ = try await store.adoptExternalSession(
                token: "cms_local_debug_fallback",
                provider: "phone"
            )
            XCTFail("a local/debug token must not publish a signed-in phone account")
        } catch {
            let currentToken = await store.sessionToken()
            XCTAssertNil(currentToken)
            XCTAssertNil(KeychainStore.get(keys.session))
        }
    }

    @MainActor
    func testIdentityQuotaAndAnalyticsStorageAreIsolatedWithoutBreakingLegacyKeys() {
        XCTAssertEqual(
            MobileSessionStore.storageKeys(for: .globalGateway).session,
            "castreader_mobile_session_v1"
        )
        XCTAssertEqual(
            MobileSessionStore.storageKeys(for: .chinaGateway).session,
            "castreader_mobile_session_v1.cn"
        )
        XCTAssertEqual(AuthService.accountDefaultsKey(for: .globalGateway), "auth_account_v1")
        XCTAssertEqual(AuthService.accountDefaultsKey(for: .chinaGateway), "auth_account_v1.cn")
        XCTAssertEqual(
            AuthService.credentialKeys(for: .globalGateway),
            .init(
                googleIDToken: "google_id_token",
                googleAccessToken: "google_access_token",
                betterAuthSessionToken: "betterauth_session_token"
            )
        )
        XCTAssertEqual(
            AuthService.credentialKeys(for: .chinaGateway),
            .init(
                googleIDToken: "google_id_token.cn",
                googleAccessToken: "google_access_token.cn",
                betterAuthSessionToken: "betterauth_session_token.cn"
            )
        )
        XCTAssertEqual(AuthService.appleBackendUserIdField(for: .globalGateway), "backendUserId")
        XCTAssertEqual(AuthService.appleBackendUserIdField(for: .chinaGateway), "backendUserId_cn")
        XCTAssertEqual(
            ServiceRoute.globalGateway.isolatedStorageKey("product_analytics_queue_v1"),
            "product_analytics_queue_v1"
        )
        XCTAssertEqual(
            ServiceRoute.chinaGateway.isolatedStorageKey("product_analytics_queue_v1"),
            "product_analytics_queue_v1.cn"
        )
    }

    func testLocalContentScopeIsolatedByCanonicalAccountAndGateway() throws {
        let accountA = UserAccount(
            id: "provider-a",
            email: "a@example.com",
            name: nil,
            pictureURL: nil,
            provider: "google",
            backendUserId: "canonical-a"
        )
        let sameCanonicalAccount = UserAccount(
            id: "email-provider-id",
            email: "a@example.com",
            name: nil,
            pictureURL: nil,
            provider: "email",
            backendUserId: "canonical-a"
        )
        let accountB = UserAccount(
            id: "canonical-b",
            email: nil,
            name: nil,
            pictureURL: nil,
            provider: "phone",
            backendUserId: "canonical-b"
        )

        let globalA = try XCTUnwrap(
            AccountContentScope(account: accountA, route: .globalGateway)
        )
        let globalAlias = try XCTUnwrap(
            AccountContentScope(account: sameCanonicalAccount, route: .globalGateway)
        )
        let chinaA = try XCTUnwrap(
            AccountContentScope(account: accountA, route: .chinaGateway)
        )
        let chinaB = try XCTUnwrap(
            AccountContentScope(account: accountB, route: .chinaGateway)
        )

        XCTAssertEqual(globalA, globalAlias, "同一 canonical 账号的登录别名应共享本地内容")
        XCTAssertNotEqual(globalA, chinaA, "同一账号跨 .ai/.cn 线路也必须隔离")
        XCTAssertNotEqual(chinaA, chinaB, "同一路线的不同账号必须隔离")
        XCTAssertEqual(globalA.storageID.count, 64)
        XCTAssertFalse(globalA.storageKey("history").contains("canonical-a"))
        XCTAssertFalse(globalA.storageKey("history").contains("a@example.com"))
    }

    func testLocalContentScopeKeepsProviderDataWhenCanonicalIDArrivesLater() throws {
        let suiteName = "ServiceRoutingTests.scope-alias.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let provisional = UserAccount(
            id: "google-provider-a",
            email: "a@example.com",
            name: nil,
            pictureURL: nil,
            provider: "google",
            backendUserId: nil
        )
        let canonicalized = UserAccount(
            id: "google-provider-a",
            email: "a@example.com",
            name: nil,
            pictureURL: nil,
            provider: "google",
            backendUserId: "canonical-a"
        )
        let emailAlias = UserAccount(
            id: "canonical-a",
            email: "a@example.com",
            name: nil,
            pictureURL: nil,
            provider: "email",
            backendUserId: "canonical-a"
        )

        let provisionalScope = try XCTUnwrap(AccountContentScope.resolved(
            account: provisional,
            route: .globalGateway,
            defaults: defaults
        ))
        let upgradedScope = try XCTUnwrap(AccountContentScope.resolved(
            account: canonicalized,
            route: .globalGateway,
            defaults: defaults
        ))
        let aliasScope = try XCTUnwrap(AccountContentScope.resolved(
            account: emailAlias,
            route: .globalGateway,
            defaults: defaults
        ))
        let chinaScope = try XCTUnwrap(AccountContentScope.resolved(
            account: canonicalized,
            route: .chinaGateway,
            defaults: defaults
        ))

        XCTAssertEqual(provisionalScope, upgradedScope)
        XCTAssertEqual(upgradedScope, aliasScope)
        XCTAssertNotEqual(upgradedScope, chinaScope)
        for (key, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse(key.contains("google-provider-a"))
            XCTAssertFalse(key.contains("canonical-a"))
            XCTAssertFalse(String(describing: value).contains("google-provider-a"))
            XCTAssertFalse(String(describing: value).contains("canonical-a"))
        }
    }

    func testOnlyServerIssuedMobileSessionsCanReachProtectedChinaAPIs() {
        XCTAssertTrue(MobileSessionStore.isServerSessionToken("cms_server_session"))
        XCTAssertFalse(MobileSessionStore.isServerSessionToken("cms_local_debug_fallback"))
        XCTAssertFalse(MobileSessionStore.isServerSessionToken("cms_"))
        XCTAssertFalse(MobileSessionStore.isServerSessionToken("google-id-token"))
        XCTAssertFalse(
            MobileSessionStore.isServerSessionToken("cms_" + String(repeating: "x", count: 4_096))
        )
    }

    @MainActor
    func testSigningOutOneRouteCannotClearOtherRouteProviderCredentials() {
        let legacy = AuthService.credentialKeys(for: .globalGateway)
        let china = AuthService.credentialKeys(for: .chinaGateway)
        let allKeys = [
            legacy.googleIDToken,
            legacy.googleAccessToken,
            legacy.betterAuthSessionToken,
            china.googleIDToken,
            china.googleAccessToken,
            china.betterAuthSessionToken,
        ]
        let savedValues = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, KeychainStore.get($0)) })
        defer {
            for key in allKeys {
                if let value = savedValues[key] ?? nil {
                    KeychainStore.set(value, for: key)
                } else {
                    KeychainStore.delete(key)
                }
            }
        }

        KeychainStore.set("legacy-id", for: legacy.googleIDToken)
        KeychainStore.set("legacy-access", for: legacy.googleAccessToken)
        KeychainStore.set("legacy-session", for: legacy.betterAuthSessionToken)
        KeychainStore.set("cn-id", for: china.googleIDToken)
        KeychainStore.set("cn-access", for: china.googleAccessToken)
        KeychainStore.set("cn-session", for: china.betterAuthSessionToken)

        AuthService.clearProviderCredentials(for: .chinaGateway)

        XCTAssertEqual(KeychainStore.get(legacy.googleIDToken), "legacy-id")
        XCTAssertEqual(KeychainStore.get(legacy.googleAccessToken), "legacy-access")
        XCTAssertEqual(KeychainStore.get(legacy.betterAuthSessionToken), "legacy-session")
        XCTAssertNil(KeychainStore.get(china.googleIDToken))
        XCTAssertNil(KeychainStore.get(china.googleAccessToken))
        XCTAssertNil(KeychainStore.get(china.betterAuthSessionToken))
    }

    // MARK: - 后台控制面客户端

    func testRemotePayloadValidatesSchemaRouteAndBuildRange() {
        let valid = ServiceRouting.RemoteConfiguration(
            schemaVersion: 1,
            iosChinaServiceRoute: "cn",
            minimumBuild: 38,
            maximumBuild: 50,
            cacheSeconds: 604_800
        )
        XCTAssertEqual(valid.validatedRoute(buildNumber: 38), .chinaGateway)
        XCTAssertEqual(valid.validatedRoute(buildNumber: 50), .chinaGateway)
        XCTAssertNil(valid.validatedRoute(buildNumber: 37))
        XCTAssertNil(valid.validatedRoute(buildNumber: 51))

        XCTAssertNil(
            ServiceRouting.RemoteConfiguration(
                schemaVersion: 2,
                iosChinaServiceRoute: "cn",
                minimumBuild: nil,
                maximumBuild: nil,
                cacheSeconds: 604_800
            ).validatedRoute(buildNumber: 39)
        )
        XCTAssertNil(
            ServiceRouting.RemoteConfiguration(
                schemaVersion: 1,
                iosChinaServiceRoute: "surprise",
                minimumBuild: nil,
                maximumBuild: nil,
                cacheSeconds: 604_800
            ).validatedRoute(buildNumber: 39)
        )
        XCTAssertNil(
            ServiceRouting.RemoteConfiguration(
                schemaVersion: 1,
                iosChinaServiceRoute: "cn",
                minimumBuild: nil,
                maximumBuild: nil,
                cacheSeconds: 604_800
            ).validatedRoute(buildNumber: 39),
            "the China gateway must never be enabled by an unbounded payload"
        )
        XCTAssertNil(
            ServiceRouting.RemoteConfiguration(
                schemaVersion: 1,
                iosChinaServiceRoute: "cn",
                minimumBuild: 50,
                maximumBuild: 38,
                cacheSeconds: 604_800
            ).validatedRoute(buildNumber: 39)
        )
        XCTAssertEqual(
            ServiceRouting.RemoteConfiguration(
                schemaVersion: 1,
                iosChinaServiceRoute: "global",
                minimumBuild: nil,
                maximumBuild: nil,
                cacheSeconds: 604_800
            ).validatedRoute(buildNumber: 39),
            .globalGateway
        )
        XCTAssertNil(
            ServiceRouting.RemoteConfiguration(
                schemaVersion: 1,
                iosChinaServiceRoute: "legacy",
                minimumBuild: nil,
                maximumBuild: nil,
                cacheSeconds: 604_800
            ).validatedRoute(buildNumber: 39),
            "the server contract must reject the retired local migration alias"
        )
    }

    func testControlPlaneURLFollowsFrozenServiceIngress() {
        XCTAssertEqual(
            ServiceRouting.remoteConfigurationURL(for: .globalGateway),
            "https://api.castreader.ai/api/mobile/runtime-config/v1"
        )
        XCTAssertEqual(
            ServiceRouting.remoteConfigurationURL(for: .chinaGateway),
            "https://api.castreader.cn/api/mobile/runtime-config/v1"
        )
    }

    func testColdStartChinaFetchesFiledControlPlaneBeforeFirstFreeze() async throws {
        let body: [String: Any] = [
            "schemaVersion": 1,
            "iosChinaServiceRoute": "cn",
            "minimumBuild": 39,
            "maximumBuild": 39,
            "cacheSeconds": 604_800,
        ]
        RoutingURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                ServiceRouting.remoteConfigurationURL(for: .chinaGateway)
            )
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, try JSONSerialization.data(withJSONObject: body))
        }
        let region = AppRegion.Resolution(
            region: .cn,
            isAuthoritative: true,
            provenance: .storefront
        )

        let snapshot = await ServiceRouting.bootstrapForCurrentProcess(
            appRegionResolution: region,
            session: makeRoutingSession(),
            buildNumber: 39,
            arguments: [],
            allowLocalOverride: false
        )

        XCTAssertEqual(snapshot, .init(route: .chinaGateway, provenance: .backend))
        XCTAssertEqual(ServiceRouting.current, .chinaGateway)
        XCTAssertEqual(ServiceRouting.cachedBackendRoute, .chinaGateway)
    }

    func testColdStartChinaControlPlaneFailureFreezesGlobalOnlyOnce() async {
        RoutingURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                ServiceRouting.remoteConfigurationURL(for: .chinaGateway)
            )
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        let region = AppRegion.Resolution(
            region: .cn,
            isAuthoritative: true,
            provenance: .storefront
        )

        let first = await ServiceRouting.bootstrapForCurrentProcess(
            appRegionResolution: region,
            session: makeRoutingSession(),
            buildNumber: 39,
            arguments: [],
            allowLocalOverride: false
        )
        XCTAssertEqual(first, .init(route: .globalGateway, provenance: .safeDefault))

        // A later valid response in the same process cannot thaw the snapshot.
        RoutingURLProtocol.handler = { request in
            let body: [String: Any] = [
                "schemaVersion": 1,
                "iosChinaServiceRoute": "cn",
                "minimumBuild": 39,
                "maximumBuild": 39,
                "cacheSeconds": 604_800,
            ]
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, try JSONSerialization.data(withJSONObject: body))
        }
        let second = await ServiceRouting.bootstrapForCurrentProcess(
            appRegionResolution: region,
            session: makeRoutingSession(),
            buildNumber: 39,
            arguments: [],
            allowLocalOverride: false
        )
        XCTAssertEqual(second, first)
        XCTAssertEqual(ServiceRouting.current, .globalGateway)
        XCTAssertNil(ServiceRouting.cachedBackendRoute)
    }

    func testProductRegionLaunchArgumentWithoutRouteArgumentStaysDeterministicGlobal() async throws {
        try saveBackendRecord(
            .chinaGateway,
            now: Date(),
            validFor: 7 * 24 * 3600,
            in: .standard
        )
        let region = AppRegion.Resolution(
            region: .cn,
            isAuthoritative: true,
            provenance: .launchArgument
        )

        let snapshot = await ServiceRouting.bootstrapForCurrentProcess(
            appRegionResolution: region,
            session: makeRoutingSession(),
            buildNumber: 39,
            arguments: ["app", "-CastReaderRegion", "cn"],
            allowLocalOverride: false
        )

        XCTAssertEqual(snapshot, .init(route: .globalGateway, provenance: .safeDefault))
        XCTAssertEqual(ServiceRouting.current, .globalGateway)
    }

    func testSuccessfulChinaControlPlaneRefreshOnlyChangesNextLaunchWhenAlreadyFrozen() async throws {
        UserDefaults.standard.set("CHN", forKey: "appRegion.v1.storefrontCountryCode")
        resetSnapshots()
        XCTAssertEqual(ServiceRouting.current, .globalGateway)

        let body: [String: Any] = [
            "schemaVersion": 1,
            "iosChinaServiceRoute": "cn",
            "minimumBuild": 38,
            "maximumBuild": 50,
            "cacheSeconds": 604_800,
        ]
        RoutingURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                ServiceRouting.remoteConfigurationURL(for: .chinaGateway)
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-castreader-build"), "39")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, try JSONSerialization.data(withJSONObject: body))
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = await ServiceRouting.refreshBackendConfiguration(
            session: makeRoutingSession(),
            now: now,
            buildNumber: 39
        )

        XCTAssertEqual(outcome, .updated(.chinaGateway))
        XCTAssertEqual(ServiceRouting.current, .globalGateway, "刷新不得切换当前进程")
        XCTAssertEqual(ServiceRouting.nextLaunchSnapshot.route, .chinaGateway)
        XCTAssertEqual(ServiceRouting.cachedBackendFetchedAt, now)
        XCTAssertEqual(
            ServiceRouting.cachedBackendExpiresAt,
            now.addingTimeInterval(7 * 24 * 3600)
        )
    }

    func testControlPlaneFailureClearsPendingChinaRouteAndFailsBackGlobal() async throws {
        UserDefaults.standard.set("CHN", forKey: "appRegion.v1.storefrontCountryCode")
        try saveBackendRecord(
            .chinaGateway,
            now: Date(),
            validFor: 7 * 24 * 3600,
            in: .standard
        )
        resetSnapshots()
        XCTAssertEqual(ServiceRouting.current, .chinaGateway)

        RoutingURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                ServiceRouting.remoteConfigurationURL(for: .chinaGateway)
            )
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        let outcome = await ServiceRouting.refreshBackendConfiguration(
            session: makeRoutingSession(),
            buildNumber: 39
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(ServiceRouting.cachedBackendRoute)
        XCTAssertEqual(ServiceRouting.current, .chinaGateway, "当前进程仍不得中途切线")
        XCTAssertEqual(ServiceRouting.nextLaunchSnapshot.route, .globalGateway)
    }

    func testChinaControlPlaneRejectsRedirectToGlobalIngress() async throws {
        UserDefaults.standard.set("CHN", forKey: "appRegion.v1.storefrontCountryCode")
        resetSnapshots()
        XCTAssertEqual(ServiceRouting.current, .globalGateway)

        let target = "https://api.castreader.ai/api/mobile/runtime-config/v1"
        RoutingRedirectURLProtocol.configure(status: 307, target: target)
        let outcome = await ServiceRouting.refreshBackendConfiguration(
            session: makePinnedControlPlaneSession(route: .chinaGateway),
            buildNumber: 39,
            requestTimeout: 0.25
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(ServiceRouting.cachedBackendRoute)
        XCTAssertEqual(ServiceRouting.current, .globalGateway)
        XCTAssertEqual(ServiceRouting.nextLaunchSnapshot.route, .globalGateway)
        XCTAssertEqual(
            RoutingRedirectURLProtocol.requestURLs,
            [ServiceRouting.remoteConfigurationURL(for: .chinaGateway)],
            "the filed control plane must never follow a redirect to .ai"
        )
    }

    func testControlPlaneRedirectHarnessDetectsWrongGlobalPinnedSessionPositiveControl() async {
        UserDefaults.standard.set("CHN", forKey: "appRegion.v1.storefrontCountryCode")
        ServiceRouting.clearBackendConfiguration()
        resetSnapshots()
        XCTAssertEqual(ServiceRouting.current, .globalGateway)

        let target = "https://api.castreader.ai/api/mobile/runtime-config/v1"
        RoutingRedirectURLProtocol.configure(status: 302, target: target)
        let outcome = await ServiceRouting.refreshBackendConfiguration(
            session: makeRedirectSession(
                route: .globalGateway,
                rejectsEveryRedirect: false
            ),
            buildNumber: 39
        )

        XCTAssertEqual(
            outcome,
            .updated(.chinaGateway),
            "positive control: a session bound to the other ingress would expose the redirect bug"
        )
        XCTAssertEqual(
            RoutingRedirectURLProtocol.requestURLs,
            [ServiceRouting.remoteConfigurationURL(for: .chinaGateway), target]
        )
    }

    // MARK: - Helpers

    private func saveBackendRecord(
        _ route: ServiceRoute,
        now: Date,
        validFor seconds: TimeInterval,
        in defaults: UserDefaults,
        minimumBuild: Int? = nil,
        maximumBuild: Int? = nil
    ) throws {
        let record = ServiceRouting.BackendCacheRecord(
            route: route,
            minimumBuild: minimumBuild ?? (route == .chinaGateway ? 1 : nil),
            maximumBuild: maximumBuild ?? (route == .chinaGateway ? 999_999 : nil),
            expiresAt: now.addingTimeInterval(seconds),
            fetchedAt: now
        )
        defaults.set(
            try JSONEncoder().encode(record),
            forKey: ServiceRouting.backendConfigurationDefaultsKey
        )
    }

    private func makeRoutingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeSTSSuccessData(prefix: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "success": true,
            "sts": [
                "accessKeyId": "\(prefix)-access",
                "secretAccessKey": "\(prefix)-secret",
                "sessionToken": "cos-session",
                "bucket": "castreader-test",
                "region": "ap-shanghai",
                "prefix": "\(prefix)/uploads/",
            ],
        ])
    }

    private static func makeQuickReadSectionData(id: String) -> Data {
        Data(
            """
            {"section":{"id":"\(id)","text":"explanation","style":"explain","cinematic":{"events":[]}}}
            """.utf8
        )
    }

    private static func makeQuickReadSSEData(id: String) -> Data {
        Data(
            """
            event: block0
            data: {"job_id":"job-\(id)","output_language":"en","total_blocks":1,"block_0":{"id":"block-0","text":"explanation","style":"explain","cinematic":{"events":[]}}}

            event: done
            data: {"job_id":"job-\(id)","total_blocks":1,"model_used":"test","page_summary":null}

            """.utf8
        )
    }

    private static func makeQuickReadFastData(id: String) -> Data {
        Data(
            """
            {"block_0":{"narration":"fast-\(id)","marks":[]},"fast_ms":1}
            """.utf8
        )
    }

    private static func makeComputeTicketData(
        token: String,
        expiresAt: Date,
        targetRoute: ServiceRoute = .chinaGateway
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try! JSONSerialization.data(withJSONObject: [
            "code": 0,
            "data": [
                "token": token,
                "expiresAt": formatter.string(from: expiresAt),
                "audience": "quickread",
                "targetRoute": targetRoute.rawValue,
            ],
        ])
    }

    private static func makeExtractPlanRequest(id: String = "compute") -> ExtractPlanRequest {
        ExtractPlanRequest(
            source_url: "castreader://test/\(id)",
            title: "Compute route",
            lang: "en",
            depth: "standard",
            text: "A paragraph.",
            fullText: "A paragraph.",
            paragraphs: [QuickreadParagraphDTO(text: "A paragraph.", type: "paragraph")]
        )
    }

    private func makePinnedControlPlaneSession(route: ServiceRoute) -> URLSession {
        makeRedirectSession(route: route, rejectsEveryRedirect: true)
    }

    private func makeRedirectSession(
        route: ServiceRoute,
        rejectsEveryRedirect: Bool
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutingRedirectURLProtocol.self]
        return OwnedAPIURLSession.make(
            configuration: configuration,
            route: route,
            rejectsEveryRedirect: rejectsEveryRedirect
        )
    }

    private func resetSnapshots() {
        AppRegion.resetProcessResolutionForTesting()
        ServiceRouting.resetProcessSnapshotForTesting()
        TTSEndpoint.resetProcessSnapshotForTesting()
        QuickReadEndpoint.resetProcessSnapshotForTesting()
    }
}

private final class RoutingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(Self.materializedRequest(request))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession may move a JSON body to an input stream before a custom
    /// URLProtocol sees it. Materialize the stream so contract assertions can
    /// inspect the exact payload sent by the client.
    private static func materializedRequest(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }
}

private actor RoutingMobileSessionProvider: MobileSessionProviding {
    private var currentToken: String?
    private let refreshedToken: String?
    private var refreshCalls = 0
    private var rejectedTokens: [String?] = []

    init(currentToken: String?, refreshedToken: String? = nil) {
        self.currentToken = currentToken
        self.refreshedToken = refreshedToken
    }

    func sessionToken() -> String? { currentToken }

    func refreshSession() -> String? {
        refreshCalls += 1
        currentToken = refreshedToken
        return refreshedToken
    }

    func invalidateSession() {
        currentToken = nil
    }

    func rejectSession(_ rejectedToken: String?) {
        rejectedTokens.append(rejectedToken)
    }

    func setCurrentToken(_ token: String?) {
        currentToken = token
    }

    func refreshCallCount() -> Int { refreshCalls }
    func rejectedSessionTokens() -> [String?] { rejectedTokens }
}

private actor RoutingComputeSessionProvider: QuickReadComputeSessionProviding {
    enum Failure: Sendable {
        case cannotConnect
        case http(Int)
    }

    private let token: String
    private let refreshedToken: String
    private let failure: Failure?
    private var forceRefreshValues: [Bool] = []
    private var invalidationCount = 0

    init(
        token: String = "cmc_initial_compute_ticket",
        refreshedToken: String = "cmc_refreshed_compute_ticket",
        failure: Failure? = nil
    ) {
        self.token = token
        self.refreshedToken = refreshedToken
        self.failure = failure
    }

    func ticket(forceRefresh: Bool) throws -> QuickReadComputeTicket {
        forceRefreshValues.append(forceRefresh)
        if let failure {
            switch failure {
            case .cannotConnect: throw URLError(.cannotConnectToHost)
            case .http(let status): throw QuickReadError.httpError(status)
            }
        }
        return QuickReadComputeTicket(
            token: forceRefresh ? refreshedToken : token,
            expiresAt: Date().addingTimeInterval(15 * 60)
        )
    }

    func invalidateTicket() {
        invalidationCount += 1
    }

    func requestedForceRefreshValues() -> [Bool] { forceRefreshValues }
    func invalidations() -> Int { invalidationCount }
}

private final class RoutingRedirectURLProtocol: URLProtocol {
    private static var status = 302
    private static var target = "https://api.castreader.ai/api/mobile/runtime-config/v1"
    private(set) static var requestURLs: [String] = []

    static func configure(status: Int, target: String) {
        self.status = status
        self.target = target
        requestURLs = []
    }

    static func reset() {
        configure(
            status: 302,
            target: "https://api.castreader.ai/api/mobile/runtime-config/v1"
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rawURL = request.url?.absoluteString ?? ""
        Self.requestURLs.append(rawURL)
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if Self.requestURLs.count == 1,
           let targetURL = URL(string: Self.target),
           let response = HTTPURLResponse(
               url: url,
               statusCode: Self.status,
               httpVersion: "HTTP/1.1",
               headerFields: ["Location": targetURL.absoluteString]
           ) {
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: targetURL),
                redirectResponse: response
            )
            return
        }

        // If the redirect guard regresses, make the cross-ingress host return an
        // otherwise valid rollout payload so the test proves it was followed.
        let body: [String: Any] = [
            "schemaVersion": 1,
            "iosChinaServiceRoute": "cn",
            "minimumBuild": 38,
            "maximumBuild": 50,
            "cacheSeconds": 604_800,
        ]
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class AccountScopedLibraryStoreTests: XCTestCase {
    func testKindleStoreSwitchesScopesWithoutLeakingLegacyOrPriorAccount() {
        withDefaults { defaults in
            let (accountA, accountB) = makeScopes()
            defaults.set(true, forKey: "kindle.library.connected.v1")
            defaults.set("Legacy Kindle", forKey: "kindle.library.account.label.v1")
            defaults.set(true, forKey: accountA.storageKey("kindle.library.connected.v1"))
            defaults.set("Kindle A", forKey: accountA.storageKey("kindle.library.account.label.v1"))
            defaults.set(true, forKey: accountB.storageKey("kindle.library.connected.v1"))
            defaults.set("Kindle B", forKey: accountB.storageKey("kindle.library.account.label.v1"))

            let store = KindleLibraryStore(defaults: defaults)
            XCTAssertEqual(store.accountLabel, "Legacy Kindle")

            store.activateAccountScope(accountA)
            XCTAssertTrue(store.hasConnected)
            XCTAssertEqual(store.accountLabel, "Kindle A")

            store.activateAccountScope(accountB)
            XCTAssertTrue(store.hasConnected)
            XCTAssertEqual(store.accountLabel, "Kindle B")

            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "Kindle A")

            store.deactivateAccountScope()
            XCTAssertFalse(store.hasConnected)
            XCTAssertNil(store.accountLabel)
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertTrue(store.listeningAnchors.isEmpty)
        }
    }

    func testWeReadStoreSwitchesScopesWithoutLeakingLegacyOrPriorAccount() {
        withDefaults { defaults in
            let (accountA, accountB) = makeScopes()
            defaults.set(true, forKey: "weread.library.connected.v1")
            defaults.set("Legacy WeRead", forKey: "weread.library.account.v1")
            defaults.set(true, forKey: accountA.storageKey("weread.library.connected.v1"))
            defaults.set("WeRead A", forKey: accountA.storageKey("weread.library.account.v1"))
            defaults.set(true, forKey: accountB.storageKey("weread.library.connected.v1"))
            defaults.set("WeRead B", forKey: accountB.storageKey("weread.library.account.v1"))

            let store = WeReadLibraryStore(defaults: defaults)
            XCTAssertEqual(store.accountLabel, "Legacy WeRead")

            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "WeRead A")
            store.activateAccountScope(accountB)
            XCTAssertEqual(store.accountLabel, "WeRead B")
            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "WeRead A")

            store.deactivateAccountScope()
            XCTAssertFalse(store.hasConnected)
            XCTAssertNil(store.accountLabel)
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertTrue(store.anchors.isEmpty)
        }
    }

    func testWeReadDebugSnapshotResetClearsOnlyTheActiveAccountScope() {
        withDefaults { defaults in
            let (accountA, accountB) = makeScopes()
            let store = WeReadLibraryStore(defaults: defaults)
            let now = Date()
            func book(_ id: String, _ title: String) -> WeReadBook {
                WeReadBook(
                    id: "weread:\(id)",
                    title: title,
                    author: "",
                    coverURL: nil,
                    readerURL: "https://weread.qq.com/web/reader/\(id)",
                    progressLabel: "",
                    bookID: id,
                    lastOpenedAt: nil,
                    lastSyncedAt: now,
                    lastPageFingerprint: nil,
                    lastReaderURL: nil
                )
            }

            store.activateAccountScope(accountA)
            let polluted = book("home-card", "首页推荐")
            store.mergeScrapedBooks([polluted])

            store.activateAccountScope(accountB)
            let accountBBook = book("account-b", "账号 B 的书")
            store.mergeScrapedBooks([accountBBook])
            store.activateAccountScope(accountA)
            store.resetCurrentAccountSnapshotForTesting()
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertFalse(store.hasConnected)

            store.activateAccountScope(accountB)
            XCTAssertEqual(store.books.map(\.id), [accountBBook.id])
            XCTAssertTrue(store.hasConnected)
        }
    }

    func testWeReadAdditiveShelfMergeNeverDeletesExistingRowsOrAnchors() {
        withDefaults { defaults in
            let (accountA, _) = makeScopes()
            let store = WeReadLibraryStore(defaults: defaults)
            store.activateAccountScope(accountA)
            let existing = WeReadBook(
                id: "weread:existing",
                title: "原有真实书",
                author: "",
                coverURL: nil,
                readerURL: "https://weread.qq.com/web/reader/existing",
                progressLabel: "",
                bookID: "existing",
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastPageFingerprint: nil,
                lastReaderURL: nil
            )
            let validNew = WeReadBook(
                id: "weread:new",
                title: "新书",
                author: "",
                coverURL: nil,
                readerURL: "https://weread.qq.com/web/reader/new",
                progressLabel: "",
                bookID: "new",
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastPageFingerprint: nil,
                lastReaderURL: nil
            )
            let invalidRow = WeReadBook(
                id: "weread:invalid",
                title: "书籍封面",
                author: "",
                coverURL: nil,
                readerURL: "https://weread.qq.com/web/reader/invalid",
                progressLabel: "",
                bookID: "invalid",
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastPageFingerprint: nil,
                lastReaderURL: nil
            )
            store.mergeScrapedBooks([existing])
            store.updateProgress(
                bookID: existing.id,
                readerURL: existing.readerURL + "?chapter=8",
                fingerprint: "page-8",
                progressLabel: "读到 8%"
            )

            store.mergeScrapedBooks([validNew, invalidRow])
            XCTAssertEqual(Set(store.books.map(\.id)), [existing.id, validNew.id])
            XCTAssertNil(store.book(for: invalidRow.id))
            XCTAssertEqual(store.book(for: existing.id)?.lastReaderURL, existing.readerURL + "?chapter=8")
            XCTAssertEqual(store.anchor(for: existing.id)?.pageFingerprint, "page-8")
        }
    }

    func testGoogleBooksStoreSwitchesScopesWithoutLeakingLegacyOrPriorAccount() {
        withDefaultsAndHistory { defaults, history in
            let (accountA, accountB) = makeScopes()
            defaults.set(true, forKey: "googlebooks.library.connected.v1")
            defaults.set("Legacy Google", forKey: "googlebooks.library.account.v1")
            defaults.set(true, forKey: accountA.storageKey("googlebooks.library.connected.v1"))
            defaults.set("Google A", forKey: accountA.storageKey("googlebooks.library.account.v1"))
            defaults.set(true, forKey: accountB.storageKey("googlebooks.library.connected.v1"))
            defaults.set("Google B", forKey: accountB.storageKey("googlebooks.library.account.v1"))

            let store = GoogleBooksLibraryStore(defaults: defaults, historyStore: history)
            XCTAssertEqual(store.accountLabel, "Legacy Google")

            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "Google A")
            store.activateAccountScope(accountB)
            XCTAssertEqual(store.accountLabel, "Google B")
            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "Google A")

            store.deactivateAccountScope()
            XCTAssertFalse(store.hasConnected)
            XCTAssertNil(store.accountLabel)
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertTrue(store.anchors.isEmpty)
        }
    }

    func testKoboStoreSwitchesScopesWithoutLeakingLegacyOrPriorAccount() {
        withDefaultsAndHistory { defaults, history in
            let (accountA, accountB) = makeScopes()
            seedIdentifiedShelf(
                defaults,
                prefix: "kobo.library",
                labelKey: "account.v1",
                identityKey: "accountIdentity.v1",
                label: "Legacy Kobo",
                identity: KoboAccountIdentity.hash("legacy-kobo")!
            )
            seedIdentifiedShelf(
                defaults,
                scope: accountA,
                prefix: "kobo.library",
                labelKey: "account.v1",
                identityKey: "accountIdentity.v1",
                label: "Kobo A",
                identity: KoboAccountIdentity.hash("kobo-a")!
            )
            seedIdentifiedShelf(
                defaults,
                scope: accountB,
                prefix: "kobo.library",
                labelKey: "account.v1",
                identityKey: "accountIdentity.v1",
                label: "Kobo B",
                identity: KoboAccountIdentity.hash("kobo-b")!
            )

            let store = KoboLibraryStore(defaults: defaults, historyStore: history)
            XCTAssertEqual(store.accountLabel, "Legacy Kobo")

            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "Kobo A")
            store.activateAccountScope(accountB)
            XCTAssertEqual(store.accountLabel, "Kobo B")
            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "Kobo A")

            store.deactivateAccountScope()
            XCTAssertFalse(store.hasConnected)
            XCTAssertNil(store.accountLabel)
            XCTAssertNil(store.accountIdentity)
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertTrue(store.anchors.isEmpty)
        }
    }

    func testOReillyStoreSwitchesScopesWithoutLeakingLegacyOrPriorAccount() {
        withDefaultsAndHistory { defaults, history in
            let (accountA, accountB) = makeScopes()
            seedIdentifiedShelf(
                defaults,
                prefix: "oreilly.library",
                labelKey: "account.v1",
                identityKey: "accountIdentity.v1",
                label: "Legacy O'Reilly",
                identity: OReillyAccountIdentity.hash("legacy-oreilly")!
            )
            seedIdentifiedShelf(
                defaults,
                scope: accountA,
                prefix: "oreilly.library",
                labelKey: "account.v1",
                identityKey: "accountIdentity.v1",
                label: "O'Reilly A",
                identity: OReillyAccountIdentity.hash("oreilly-a")!
            )
            seedIdentifiedShelf(
                defaults,
                scope: accountB,
                prefix: "oreilly.library",
                labelKey: "account.v1",
                identityKey: "accountIdentity.v1",
                label: "O'Reilly B",
                identity: OReillyAccountIdentity.hash("oreilly-b")!
            )

            let store = OReillyLibraryStore(defaults: defaults, historyStore: history)
            XCTAssertEqual(store.accountLabel, "Legacy O'Reilly")

            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "O'Reilly A")
            store.activateAccountScope(accountB)
            XCTAssertEqual(store.accountLabel, "O'Reilly B")
            store.activateAccountScope(accountA)
            XCTAssertEqual(store.accountLabel, "O'Reilly A")

            store.deactivateAccountScope()
            XCTAssertFalse(store.hasConnected)
            XCTAssertNil(store.accountLabel)
            XCTAssertNil(store.accountIdentity)
            XCTAssertTrue(store.books.isEmpty)
            XCTAssertTrue(store.anchors.isEmpty)
        }
    }

    private func makeScopes() -> (AccountContentScope, AccountContentScope) {
        let accountA = UserAccount(
            id: "phone-a",
            email: nil,
            name: nil,
            pictureURL: nil,
            provider: "phone",
            backendUserId: "backend-a"
        )
        let accountB = UserAccount(
            id: "phone-b",
            email: nil,
            name: nil,
            pictureURL: nil,
            provider: "phone",
            backendUserId: "backend-b"
        )
        return (
            AccountContentScope(account: accountA, route: .chinaGateway)!,
            AccountContentScope(account: accountB, route: .chinaGateway)!
        )
    }

    private func seedIdentifiedShelf(
        _ defaults: UserDefaults,
        scope: AccountContentScope? = nil,
        prefix: String,
        labelKey: String,
        identityKey: String,
        label: String,
        identity: String
    ) {
        func key(_ suffix: String) -> String {
            let legacy = "\(prefix).\(suffix)"
            return scope?.storageKey(legacy) ?? legacy
        }
        defaults.set(true, forKey: key("connected.v1"))
        defaults.set(label, forKey: key(labelKey))
        defaults.set(identity, forKey: key(identityKey))
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "AccountScopedLibraryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        body(defaults)
    }

    private func withDefaultsAndHistory(
        _ body: (UserDefaults, HistoryStore) -> Void
    ) {
        withDefaults { defaults in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AccountScopedLibraryStoreTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            body(defaults, HistoryStore(directory: directory))
        }
    }
}
