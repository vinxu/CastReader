//
//  AppRegionTests.swift
//  CastReaderTests
//
//  区域判定与「中国区改动不影响其他国家」的回归护栏。
//

import XCTest
@testable import CastReader

final class AppRegionTests: XCTestCase {

    private let storefrontKey = "appRegion.v1.storefrontCountryCode"
    private let overrideKey = "appRegion.v1.override"
    private let serviceOverrideKey = "serviceRouting.v1.override"
    private let serviceBackendKey = "serviceRouting.v1.backendConfiguration"
    private var savedStorefront: String?
    private var savedOverride: String?
    private var savedServiceOverride: String?
    private var savedServiceBackend: Data?

    override func setUp() {
        super.setUp()
        savedStorefront = UserDefaults.standard.string(forKey: storefrontKey)
        savedOverride = UserDefaults.standard.string(forKey: overrideKey)
        savedServiceOverride = UserDefaults.standard.string(forKey: serviceOverrideKey)
        savedServiceBackend = UserDefaults.standard.data(forKey: serviceBackendKey)
        UserDefaults.standard.removeObject(forKey: storefrontKey)
        UserDefaults.standard.removeObject(forKey: overrideKey)
        UserDefaults.standard.removeObject(forKey: serviceOverrideKey)
        UserDefaults.standard.removeObject(forKey: serviceBackendKey)
        AppRegion.resetProcessResolutionForTesting()
        ServiceRouting.resetProcessSnapshotForTesting()
        TTSEndpoint.resetProcessSnapshotForTesting()
        QuickReadEndpoint.resetProcessSnapshotForTesting()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storefrontKey)
        UserDefaults.standard.removeObject(forKey: overrideKey)
        UserDefaults.standard.removeObject(forKey: serviceOverrideKey)
        UserDefaults.standard.removeObject(forKey: serviceBackendKey)
        if let savedStorefront {
            UserDefaults.standard.set(savedStorefront, forKey: storefrontKey)
        }
        if let savedOverride {
            UserDefaults.standard.set(savedOverride, forKey: overrideKey)
        }
        if let savedServiceOverride {
            UserDefaults.standard.set(savedServiceOverride, forKey: serviceOverrideKey)
        }
        if let savedServiceBackend {
            UserDefaults.standard.set(savedServiceBackend, forKey: serviceBackendKey)
        }
        AppRegion.resetProcessResolutionForTesting()
        ServiceRouting.resetProcessSnapshotForTesting()
        TTSEndpoint.resetProcessSnapshotForTesting()
        QuickReadEndpoint.resetProcessSnapshotForTesting()
        super.tearDown()
    }

    // MARK: - 判定

    func testStorefrontCHNResolvesToChinaMainland() {
        UserDefaults.standard.set("CHN", forKey: storefrontKey)
        XCTAssertEqual(AppRegion.current, .cn)
        XCTAssertTrue(AppRegion.isAuthoritative)
    }

    /// 其他国家一律 global —— 这是「不影响其他国家」的核心断言。
    func testNonChinaStorefrontsAllResolveToGlobal() {
        for code in ["USA", "GBR", "JPN", "DEU", "FRA", "BRA", "IND", "HKG", "TWN", "MAC"] {
            UserDefaults.standard.set(code, forKey: storefrontKey)
            XCTAssertEqual(AppRegion.current, .global, "storefront \(code) 必须是 global")
        }
    }

    func testOverrideBeatsStorefront() {
        UserDefaults.standard.set("CHN", forKey: storefrontKey)
        AppRegion.overrideRegion = .global
        XCTAssertEqual(AppRegion.current, .global)

        UserDefaults.standard.set("USA", forKey: storefrontKey)
        AppRegion.overrideRegion = .cn
        XCTAssertEqual(AppRegion.current, .cn)

        AppRegion.overrideRegion = nil
        XCTAssertEqual(AppRegion.current, .global)
    }

    func testUnresolvedStorefrontIsNotAuthoritative() {
        XCTAssertFalse(AppRegion.isAuthoritative)
    }

    /// 空字符串是脏数据，不能被当成「已解析且非中国」。
    func testEmptyStorefrontCodeIsNotAuthoritative() {
        UserDefaults.standard.set("", forKey: storefrontKey)
        XCTAssertFalse(AppRegion.isAuthoritative)
    }

    func testLaunchPreparationUsesCurrentStorefrontInsteadOfTimezoneOrStaleCache() async {
        UserDefaults.standard.set("USA", forKey: storefrontKey)

        let resolution = await AppRegion.prepareForCurrentProcess {
            "CHN"
        }

        XCTAssertEqual(
            resolution,
            .init(region: .cn, isAuthoritative: true, provenance: .storefront)
        )
        XCTAssertEqual(AppRegion.resolvedStorefrontCode, "CHN")
        XCTAssertEqual(AppRegion.current, .cn)
    }

    func testLaunchPreparationOfflineRetainsCachedChinaStorefront() async {
        UserDefaults.standard.set("CHN", forKey: storefrontKey)

        let resolution = await AppRegion.prepareForCurrentProcess {
            nil
        }

        XCTAssertEqual(
            resolution,
            .init(region: .cn, isAuthoritative: true, provenance: .storefront)
        )
        XCTAssertEqual(AppRegion.resolvedStorefrontCode, "CHN")
        XCTAssertEqual(AppRegion.current, .cn)
        XCTAssertTrue(AppRegion.isAuthoritative)
    }

    func testLaunchPreparationFirstInstallWithoutStorefrontFailsClosedGlobal() async {
        XCTAssertNil(AppRegion.resolvedStorefrontCode)

        let resolution = await AppRegion.prepareForCurrentProcess {
            nil
        }

        XCTAssertEqual(
            resolution,
            .init(region: .global, isAuthoritative: true, provenance: .safeDefault)
        )
        XCTAssertNil(AppRegion.resolvedStorefrontCode)
        XCTAssertEqual(AppRegion.current, .global)
        XCTAssertTrue(AppRegion.isAuthoritative)
    }

    func testLaunchPreparationTimeoutRetainsCachedAuthoritativeStorefront() async {
        UserDefaults.standard.set("CHN", forKey: storefrontKey)
        let startedAt = Date()

        let resolution = await AppRegion.prepareForCurrentProcess(
            storefrontTimeout: 0.05
        ) {
            try? await Task.sleep(for: .seconds(30))
            return "USA"
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1,
            "StoreKit 未返回时启动必须由真实 deadline 截断"
        )
        XCTAssertEqual(
            resolution,
            .init(region: .cn, isAuthoritative: true, provenance: .storefront)
        )
        XCTAssertEqual(AppRegion.resolvedStorefrontCode, "CHN")
    }

    func testLaunchPreparationTimeoutOnFirstInstallFailsClosedGlobal() async {
        let startedAt = Date()

        let resolution = await AppRegion.prepareForCurrentProcess(
            storefrontTimeout: 0.05
        ) {
            try? await Task.sleep(for: .seconds(30))
            return "CHN"
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1,
            "首次安装也不能被 StoreKit 无限阻塞"
        )
        XCTAssertEqual(
            resolution,
            .init(region: .global, isAuthoritative: true, provenance: .safeDefault)
        )
        XCTAssertNil(AppRegion.resolvedStorefrontCode)
    }

    func testExplicitLaunchRegionSkipsStorefrontProvider() async {
        let resolution = await AppRegion.prepareForCurrentProcess(
            arguments: ["app", "-CastReaderRegion", "cn"]
        ) {
            return "USA"
        }

        XCTAssertEqual(
            resolution,
            .init(region: .cn, isAuthoritative: true, provenance: .launchArgument)
        )
        XCTAssertEqual(
            AppRegion.resolve(
                defaults: .standard,
                arguments: ["app", "-CastReaderRegion", "cn"],
                timeZoneIdentifier: "America/Los_Angeles",
                allowLocalOverride: false
            ),
            .init(region: .cn, isAuthoritative: true, provenance: .launchArgument)
        )
    }

    func testProvenanceReportsWhichSignalDecided() {
        XCTAssertEqual(AppRegion.provenance, .timeZone)
        UserDefaults.standard.set("USA", forKey: storefrontKey)
        XCTAssertEqual(AppRegion.provenance, .storefront)
        AppRegion.overrideRegion = .cn
        XCTAssertEqual(AppRegion.provenance, .userOverride)
        AppRegion.overrideRegion = nil
    }

    // MARK: - 能力矩阵

    func testGlobalKeepsEveryBoundLibrary() {
        XCTAssertEqual(
            AppRegion.global.availableBoundLibraries,
            [.kindle, .weread, .googleBooks, .kobo, .oreilly]
        )
        XCTAssertEqual(AppRegion.global.onboardingSource, .kindle)
        XCTAssertTrue(AppRegion.global.showsGoogleSignIn)
        XCTAssertFalse(AppRegion.global.showsPhoneSignIn)
        XCTAssertTrue(AppRegion.global.showsEmailSignIn)
        XCTAssertTrue(AppRegion.global.showsYouTubeEntry)
        XCTAssertEqual(AppRegion.global.currencySymbol, "$")
    }

    /// 中国区把微信读书排第一，但所有既有书库仍可手动绑定。
    func testChinaPrefersWeReadButStillAllowsManualBinding() {
        XCTAssertEqual(
            AppRegion.cn.availableBoundLibraries,
            [.weread, .kindle, .googleBooks, .kobo, .oreilly]
        )
        // 默认书库仍是微信读书——可绑定不等于默认。
        XCTAssertEqual(AppRegion.cn.onboardingSource, .weread)
        XCTAssertFalse(AppRegion.cn.showsGoogleSignIn)
        XCTAssertTrue(AppRegion.cn.showsPhoneSignIn)
        XCTAssertFalse(AppRegion.cn.showsEmailSignIn)
        XCTAssertFalse(AppRegion.cn.showsYouTubeEntry)
        XCTAssertEqual(AppRegion.cn.currencySymbol, "¥")
    }

    // MARK: - 登录协议门禁

    func testGlobalLoginActionExecutesWithoutExplicitConsent() {
        var gate = LoginConsentGate()

        XCTAssertEqual(
            gate.request(.google, requiresExplicitConsent: false),
            .execute(.google)
        )
        XCTAssertFalse(gate.hasAgreed)
        XCTAssertNil(gate.pendingAction)
    }

    func testChinaLoginActionWaitsForConsentThenResumesSameAction() {
        var gate = LoginConsentGate()

        XCTAssertEqual(
            gate.request(.phone, requiresExplicitConsent: true),
            .requestConsent
        )
        XCTAssertEqual(gate.pendingAction, .phone)
        XCTAssertEqual(gate.acceptPendingAction(), .phone)
        XCTAssertTrue(gate.hasAgreed)
        XCTAssertNil(gate.pendingAction)

        XCTAssertEqual(
            gate.request(.apple, requiresExplicitConsent: true),
            .execute(.apple)
        )
    }

    func testDecliningChinaConsentNeverExecutesStaleLoginAction() {
        var gate = LoginConsentGate()

        XCTAssertEqual(
            gate.request(.apple, requiresExplicitConsent: true),
            .requestConsent
        )
        gate.declinePendingAction()

        XCTAssertFalse(gate.hasAgreed)
        XCTAssertNil(gate.pendingAction)
        XCTAssertNil(gate.acceptPendingAction())
    }

    func testUncheckingChinaConsentRequiresPromptAgain() {
        var gate = LoginConsentGate()
        gate.setAgreement(true)
        XCTAssertEqual(
            gate.request(.sendEmailCode, requiresExplicitConsent: true),
            .execute(.sendEmailCode)
        )

        gate.setAgreement(false)
        XCTAssertEqual(
            gate.request(.verifyEmailCode, requiresExplicitConsent: true),
            .requestConsent
        )
        XCTAssertEqual(gate.pendingAction, .verifyEmailCode)
    }

    /// CHN 产品体验不能自动改变服务线路；无灰度配置时安全走全球网关。
    func testChinaProductRegionDefaultsToGlobalGateway() {
        UserDefaults.standard.set("CHN", forKey: storefrontKey)
        XCTAssertEqual(ServiceRouting.current, .globalGateway)
        XCTAssertEqual(Constants.API.webURL, Constants.API.globalWebURL)
    }

    func testWebURLIsAlwaysGlobalOutsideChina() {
        UserDefaults.standard.set("USA", forKey: storefrontKey)
        XCTAssertEqual(Constants.API.webURL, Constants.API.globalWebURL)
        XCTAssertEqual(Constants.API.proStatus, "https://api.castreader.ai/api/pro/status")
        XCTAssertEqual(Constants.API.analyticsEvents, "https://api.castreader.ai/api/events")
    }

    func testChinaUsesFiledGeneralGatewayAndDedicatedQuickReadIngress() async {
        UserDefaults.standard.set("CHN", forKey: storefrontKey)
        ServiceRouting.overrideRoute = .chinaGateway
        ServiceRouting.resetProcessSnapshotForTesting()
        TTSEndpoint.resetProcessSnapshotForTesting()
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
        XCTAssertEqual(
            Constants.API.sts,
            "https://api.castreader.cn/api/mobile/upload/sts"
        )
        XCTAssertEqual(Constants.API.asyncUpload, "https://api.castreader.cn/api/mobile/upload/notify")
        XCTAssertEqual(Constants.API.ttsCatalog, "https://api.castreader.cn/api/tts/catalog?contract=tts-voice-catalog-v1")
        XCTAssertEqual(TTSEndpoint.primaryBase(), "https://api.castreader.cn")
        XCTAssertNil(TTSEndpoint.fallbackBase())
        XCTAssertEqual(QuickReadEndpoint.base(), "https://quickread.castreader.cn")
    }

    func testGlobalServiceGatewayStaysOnDotAI() async {
        UserDefaults.standard.set("USA", forKey: storefrontKey)
        ServiceRouting.overrideRoute = .globalGateway
        ServiceRouting.resetProcessSnapshotForTesting()
        TTSEndpoint.resetProcessSnapshotForTesting()
        _ = await ComputeRouting.bootstrapForCurrentProcess(
            timeZoneIdentifier: "Asia/Shanghai",
            arguments: [],
            simCountryCodes: [],
            precomputedProbe: .init(
                china: .unavailable,
                global: .unavailable,
                country: nil
            )
        )

        XCTAssertEqual(Constants.API.baseURL, "https://api.castreader.ai")
        XCTAssertEqual(Constants.API.documents, "https://api.castreader.ai/api/mobile/documents")
        XCTAssertEqual(Constants.API.tts, "https://api.castreader.ai/api/captioned_speech_partly")
        XCTAssertEqual(Constants.API.webURL, "https://api.castreader.ai")
        XCTAssertEqual(QuickReadEndpoint.base(), "https://api.castreader.ai")
        // Account, content and generation remain in the same regional boundary
        // even when the physical network/time zone is mainland China.
        XCTAssertEqual(TTSEndpoint.primaryBase(), "https://tts.castreader.ai")
        XCTAssertEqual(TTSEndpoint.fallbackBase(), "https://api.castreader.ai")
    }

    // MARK: - 引导步骤

    /// 微信读书是单站点，引导比 Kindle 少一屏。
    func testOnlyKindleRequiresStorefrontSelection() {
        XCTAssertTrue(BoundLibraryOnboardingSource.kindle.requiresStorefrontSelection)
        for source in [BoundLibraryOnboardingSource.weread, .googleBooks, .kobo, .oreilly] {
            XCTAssertFalse(
                source.requiresStorefrontSelection,
                "\(source.rawValue) 不该有站点确认屏"
            )
        }
    }

    // MARK: - 跨区域持久化选择（首页死按钮回归）

    /// global 下绑定过 Google Play 图书、之后区域解析为 CN：选择仍然保留。
    /// 微信读书只是中国区默认引导，不会覆盖用户已明确选择的平台。
    @MainActor
    func testPersistedGoogleBooksSelectionSurvivesInChina() {
        let suiteName = "AppRegionTests.crossRegionSelection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            BoundLibraryOnboardingSource.googleBooks.rawValue,
            forKey: "boundLibraryOnboarding.v1.selectedSource"
        )
        AppRegion.overrideRegion = .cn
        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])

        XCTAssertEqual(store.selectedSource, .googleBooks, "持久化值本身要保留，不能清除")
        XCTAssertEqual(store.regionAvailableSelectedSource, .googleBooks)
        XCTAssertEqual(store.flowSource, .googleBooks)

        // 区域切回 global（例如时区兜底误判被 storefront 纠正）后选择自动恢复。
        AppRegion.overrideRegion = .global
        XCTAssertEqual(store.regionAvailableSelectedSource, .googleBooks)
        XCTAssertEqual(store.flowSource, .googleBooks)
    }

    /// CN 下仍可手动绑定的书库（Kindle / Kobo / O'Reilly）不受过滤影响。
    @MainActor
    func testPersistedKindleSelectionSurvivesInChina() {
        let suiteName = "AppRegionTests.crossRegionSelection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            BoundLibraryOnboardingSource.kindle.rawValue,
            forKey: "boundLibraryOnboarding.v1.selectedSource"
        )
        AppRegion.overrideRegion = .cn
        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])

        XCTAssertEqual(store.regionAvailableSelectedSource, .kindle)
        XCTAssertEqual(store.flowSource, .kindle)
    }
}
