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
        XCTAssertEqual(AppRegion.global.currencySymbol, "$")
    }

    /// 中国区把微信读书排第一，但 Kindle / Kobo / O'Reilly 仍可手动绑定——
    /// 国内用户可能持有这些账号。只有境内打不开的 Google 图书被排除。
    func testChinaPrefersWeReadButStillAllowsManualBinding() {
        XCTAssertEqual(
            AppRegion.cn.availableBoundLibraries,
            [.weread, .kindle, .kobo, .oreilly]
        )
        XCTAssertFalse(
            AppRegion.cn.availableBoundLibraries.contains(.googleBooks),
            "play.google.com 在境内不可访问，不该给入口"
        )
        // 默认书库仍是微信读书——可绑定不等于默认。
        XCTAssertEqual(AppRegion.cn.onboardingSource, .weread)
        XCTAssertFalse(AppRegion.cn.showsGoogleSignIn)
        XCTAssertTrue(AppRegion.cn.showsPhoneSignIn)
        XCTAssertEqual(AppRegion.cn.webBaseURL, "https://api.castreader.cn")
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

    /// global 下绑了 Google Play 图书、之后区域解析为 CN：持久化选择在 CN
    /// 不可用，读取层必须视同未选择并回退微信读书。否则首页引导卡会渲染
    /// 「绑定 Google Play 图书」，点击被 MainTabView 的区域闸门吞掉，按钮死掉。
    @MainActor
    func testPersistedGoogleBooksSelectionIsIgnoredInChina() {
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
        XCTAssertNil(
            store.regionAvailableSelectedSource,
            "CN 下 Google 图书不可绑定，必须视同未选择"
        )
        XCTAssertEqual(store.flowSource, .weread, "首页卡片与引导流程回退区域默认书库")

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
