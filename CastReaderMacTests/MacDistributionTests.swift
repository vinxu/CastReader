import XCTest
@testable import CastReader

final class MacDistributionTests: XCTestCase {
    func testMacRequestsAndConsentIdentifyTheDesktopProduct() {
        XCTAssertEqual(Constants.clientPlatform, "macos")
        XCTAssertEqual(VoiceCloneCreateMetadata.consentSource, "macos")
    }

    private var suite: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "MacDistributionTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        ServiceRouting.resetProcessSnapshotForTesting()
        ComputeRouting.resetProcessSnapshotForTesting()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        ServiceRouting.resetProcessSnapshotForTesting()
        ComputeRouting.resetProcessSnapshotForTesting()
        super.tearDown()
    }

    func testMacBuildHasGlobalOnlyPolicyEvenForInternalDistribution() {
        XCTAssertTrue(DistributionTestingPolicy.isGlobalOnly)
        XCTAssertFalse(DistributionTestingPolicy.allowsPersistedOverrides)
        for debug in [true, false] {
            for internalBuild in [true, false] {
                XCTAssertFalse(DistributionTestingPolicy.allowsPersistedOverrides(
                    isDebugBuild: debug, isInternalDistributionBuild: internalBuild,
                    appStoreReceiptURL: URL(fileURLWithPath: "/sandboxReceipt"),
                    arguments: [DistributionTestingPolicy.allowPersistedOverridesLaunchArgument]))
            }
        }
    }

    func testEveryStorefrontAndTimeZoneKeepsInternationalProduct() {
        for country in ["CHN", "USA", "HKG", "", "INVALID"] {
            suite.set(country, forKey: "appRegion.v1.storefrontCountryCode")
            for zone in ["Asia/Shanghai", "Asia/Urumqi", "America/Los_Angeles"] {
                let actual = AppRegion.resolve(defaults: suite, arguments: [], timeZoneIdentifier: zone)
                XCTAssertEqual(actual, .init(region: .global, isAuthoritative: true, provenance: .safeDefault))
            }
        }
    }

    func testCNOverridesAndLaunchArgumentsCannotChangeProduct() {
        suite.set("cn", forKey: AppRegion.overrideDefaultsKey)
        XCTAssertEqual(AppRegion.resolve(
            defaults: suite, arguments: ["app", "-CastReaderRegion", "cn"],
            timeZoneIdentifier: "Asia/Shanghai", allowLocalOverride: true).region, .global)
    }

    func testLaunchNeverWaitsForStorefrontOrExposesCNOnFirstFrame() async {
        let result = await AppRegion.prepareForCurrentProcess(
            arguments: ["app", "-CastReaderRegion", "cn"]
        ) {
            XCTFail("Global-only Mac must not request storefront resolution")
            return "CHN"
        }
        XCTAssertEqual(result, .init(region: .global, isAuthoritative: true, provenance: .safeDefault))
        XCTAssertEqual(AppRegion.current, .global)
        XCTAssertTrue(AppRegion.isAuthoritative)
    }

    func testCNCacheOverridesAndAuthoritativeStorefrontCannotChangeAccountRoute() throws {
        let now = Date()
        let record = ServiceRouting.BackendCacheRecord(route: .chinaGateway,
            minimumBuild: 1, maximumBuild: 9999,
            expiresAt: now.addingTimeInterval(86400), fetchedAt: now)
        suite.set(try JSONEncoder().encode(record), forKey: ServiceRouting.backendConfigurationDefaultsKey)
        suite.set("cn", forKey: ServiceRouting.overrideDefaultsKey)
        for arguments in [[], ["app", "-CastReaderServiceRoute", "cn"]] {
            for authoritative in [true, false] {
                XCTAssertEqual(ServiceRouting.resolve(defaults: suite, arguments: arguments,
                    now: now, appRegion: .cn, isAppRegionAuthoritative: authoritative,
                    buildNumber: 72, allowLocalOverride: true).route, .globalGateway)
            }
        }
    }

    func testComputeAndOwnedEndpointsFollowGlobalAccountDespiteCNLocation() async {
        let account = await ServiceRouting.bootstrapForCurrentProcess(
            appRegionResolution: .init(region: .cn, isAuthoritative: true, provenance: .storefront),
            arguments: ["app", "-CastReaderServiceRoute", "cn"], allowLocalOverride: true)
        let compute = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "Asia/Shanghai",
            arguments: ["app", "-CastReaderComputeRoute", "cn"], simCountryCodes: ["CN"],
            precomputedProbe: .init(china: .init(isReachable: true, latency: 0.01),
                global: .unavailable, country: .init(countryCode: "CN")))
        XCTAssertEqual(account.route, .globalGateway)
        XCTAssertEqual(compute.primary, .globalGateway)
        XCTAssertEqual(compute.provenance, .accountRoute)
        for value in [Constants.API.baseURL, Constants.API.webURL,
                      Constants.API.quickReadBaseURL, Constants.API.clonedVoiceTTS,
                      Constants.API.documents, Constants.API.sts] {
            XCTAssertEqual(URL(string: value)?.host, "api.castreader.ai", value)
        }
        // Preserve the current iOS preset transport: direct global TTS with
        // its existing same-region gateway fallback, never a CN fallback.
        XCTAssertEqual(TTSEndpoint.primaryBase(), "https://tts.castreader.ai")
        XCTAssertEqual(TTSEndpoint.fallbackBase(), "https://api.castreader.ai")
        XCTAssertEqual(TTSEndpoint.candidateRoutes(), [.globalGateway])
    }

    func testInternationalEntryPointsRetainChineseContentAndWeRead() {
        let region = AppRegion.current
        XCTAssertTrue(region.showsGoogleSignIn)
        XCTAssertTrue(region.showsEmailSignIn)
        XCTAssertFalse(region.showsPhoneSignIn)
        XCTAssertTrue(region.showsYouTubeEntry)
        XCTAssertEqual(region.availableBoundLibraries, [.kindle, .weread, .googleBooks, .kobo, .oreilly])
        XCTAssertEqual(region.onboardingSource, .kindle)
    }

    func testRunningProcessCannotBeMovedByLaterCNBootstrap() async {
        let first = ServiceRouting.freezeForCurrentProcess()
        let next = await ServiceRouting.bootstrapForCurrentProcess(
            appRegionResolution: .init(region: .cn, isAuthoritative: true, provenance: .storefront),
            arguments: ["-CastReaderServiceRoute", "cn"])
        XCTAssertEqual(first, next)
        XCTAssertEqual(ServiceRouting.nextLaunchSnapshot.route, .globalGateway)
    }
}
