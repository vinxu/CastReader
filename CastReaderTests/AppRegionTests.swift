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
    private var savedStorefront: String?
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedStorefront = UserDefaults.standard.string(forKey: storefrontKey)
        savedOverride = UserDefaults.standard.string(forKey: overrideKey)
        UserDefaults.standard.removeObject(forKey: storefrontKey)
        UserDefaults.standard.removeObject(forKey: overrideKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storefrontKey)
        UserDefaults.standard.removeObject(forKey: overrideKey)
        if let savedStorefront {
            UserDefaults.standard.set(savedStorefront, forKey: storefrontKey)
        }
        if let savedOverride {
            UserDefaults.standard.set(savedOverride, forKey: overrideKey)
        }
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
        XCTAssertEqual(AppRegion.global.webBaseURL, "https://castreader.ai")
        XCTAssertEqual(AppRegion.global.apiGatewayBaseURL, "https://api.castreader.ai")
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
        XCTAssertTrue(AppRegion.cn.showsGoogleSignIn)
        XCTAssertTrue(AppRegion.cn.showsPhoneSignIn)
        XCTAssertEqual(AppRegion.cn.webBaseURL, "https://api.castreader.cn")
        XCTAssertEqual(AppRegion.cn.apiGatewayBaseURL, "https://api.castreader.cn")
        XCTAssertEqual(AppRegion.cn.currencySymbol, "¥")
    }

    /// 开关打开时 CN 设备走境内后端，关闭时退回全球后端。
    ///
    /// 写成随开关分支而不是写死某一个值：这个开关是备案被拦时的回退阀门，
    /// 断言写死会让「关掉它」这个应急操作顺带挂掉测试。
    func testWebURLFollowsChinaBackendSwitch() {
        UserDefaults.standard.set("CHN", forKey: storefrontKey)
        if Constants.Features.chinaBackendEnabled {
            XCTAssertEqual(Constants.API.webURL, "https://api.castreader.cn")
        } else {
            XCTAssertEqual(Constants.API.webURL, Constants.API.globalWebURL)
        }
    }

    func testWebURLIsAlwaysGlobalOutsideChina() {
        UserDefaults.standard.set("USA", forKey: storefrontKey)
        XCTAssertEqual(Constants.API.webURL, Constants.API.globalWebURL)
        XCTAssertEqual(Constants.API.proStatus, "https://castreader.ai/api/pro/status")
        XCTAssertEqual(Constants.API.analyticsEvents, "https://castreader.ai/api/events")
    }

    func testChinaRoutesEveryOwnedServiceThroughFiledGateway() {
        UserDefaults.standard.set("CHN", forKey: storefrontKey)

        XCTAssertEqual(Constants.API.baseURL, "https://api.castreader.cn")
        XCTAssertEqual(Constants.API.documents, "https://api.castreader.cn/documents")
        XCTAssertEqual(Constants.API.sts, "https://api.castreader.cn/sts")
        XCTAssertEqual(Constants.API.asyncUpload, "https://api.castreader.cn/async-md-upload-by-url")
        XCTAssertEqual(Constants.API.syncUpload, "https://api.castreader.cn/upload")
        XCTAssertEqual(Constants.API.ttsCatalog, "https://api.castreader.cn/api/tts/catalog?contract=tts-voice-catalog-v1")
        XCTAssertEqual(TTSEndpoint.primaryBase(), "https://api.castreader.cn")
        XCTAssertNil(TTSEndpoint.fallbackBase())
        XCTAssertEqual(QuickReadEndpoint.base(), "https://api.castreader.cn")
    }

    func testGlobalServiceGatewayStaysOnDotAI() {
        UserDefaults.standard.set("USA", forKey: storefrontKey)

        XCTAssertEqual(Constants.API.baseURL, "https://api.castreader.ai")
        XCTAssertEqual(Constants.API.documents, "https://api.castreader.ai/documents")
        XCTAssertEqual(Constants.API.tts, "https://api.castreader.ai/api/captioned_speech_partly")
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
