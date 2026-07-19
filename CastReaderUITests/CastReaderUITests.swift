//
//  CastReaderUITests.swift
//  CastReaderUITests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest
import UIKit

class CastReaderUITests: XCTestCase {

    /// 声音克隆发布开关关闭时，不向用户暴露尚未开放的「已创建」入口。
    func testVoiceBrowserHidesCreatedTabWhileFeatureDisabled() throws {
        let app = launchZh()
        app.tabBars.buttons["音色"].tap()
        XCTAssertTrue(app.buttons["探索"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["已创建"].exists)
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        _ = launchZh()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    // MARK: - 场景化首页 + 导航 P0 交互自检

    /// 强制中文 locale 启动（模拟器默认英文时也按中文断言）。
    private func launchZh() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    /// 八个正式语言包都必须能独立启动，并显示各自的首页标签。
    func testLaunchesInAllEightSupportedLanguages() {
        let configurations: [(language: String, locale: String, home: String)] = [
            ("en", "en_US", "Home"),
            ("zh-Hans", "zh_CN", "首页"),
            ("ja", "ja_JP", "ホーム"),
            ("es", "es_ES", "Inicio"),
            ("fr", "fr_FR", "Accueil"),
            ("pt-BR", "pt_BR", "Início"),
            ("it", "it_IT", "Home"),
            ("hi", "hi_IN", "होम")
        ]

        for configuration in configurations {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(\(configuration.language))",
                "-AppleLocale", configuration.locale
            ]
            app.launch()
            XCTAssertTrue(
                app.tabBars.buttons[configuration.home].waitForExistence(timeout: 5),
                "Missing localized Home tab for \(configuration.language)"
            )
            app.terminate()
        }
    }

    func testCanSwitchInterfaceLanguageInsideTheApp() {
        let app = launchZh()
        app.buttons["settingsGearButton"].tap()
        XCTAssertTrue(app.buttons["settingsLanguageLink"].waitForExistence(timeout: 5))
        app.buttons["settingsLanguageLink"].tap()
        XCTAssertTrue(app.buttons["appLanguage.en"].waitForExistence(timeout: 5))
        app.buttons["appLanguage.en"].tap()
        XCTAssertTrue(app.navigationBars["Language"].waitForExistence(timeout: 5))

        // Leave the shared simulator state deterministic for the remaining tests.
        app.buttons["appLanguage.zh-Hans"].tap()
        XCTAssertTrue(app.navigationBars["语言"].waitForExistence(timeout: 5))
    }

    /// 首页渲染横向场景 chips，并把 Kindle 作为独立内容源展示。
    func testHomeShowsScenarioChipsAndKindle() {
        let app = launchZh()
        XCTAssertTrue(app.staticTexts["解读场景"].waitForExistence(timeout: 5))
        for id in ["scenario-paper", "scenario-book", "scenario-report", "scenario-contract", "scenario-study", "scenario-manual"] {
            XCTAssertTrue(app.buttons[id].exists, "缺场景 chip: \(id)")
        }
        XCTAssertTrue(app.staticTexts["Kindle"].exists)
        XCTAssertTrue(app.buttons["connectKindleButton"].exists)
    }

    /// 底部中间 ➕ 保持原行为，弹出快速导入面板。
    func testPlusOpensImportSheet() {
        let app = launchZh()
        let plus = app.buttons["plusImportButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(app.buttons["上传文件"].waitForExistence(timeout: 5), "➕ 未弹出导入方式")
        XCTAssertTrue(app.buttons["输入网址"].exists)
    }

    /// 首页和中间 ➕ 保持不变，只把右侧 Settings 替换成 Voice。
    func testHomePlusAndVoiceNavigation() {
        let app = launchZh()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plusImportButton"].exists)
        XCTAssertTrue(app.tabBars.buttons["音色"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["设置"].exists)

        app.tabBars.buttons["音色"].tap()
        XCTAssertTrue(app.navigationBars["音色"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["探索"].exists)
        XCTAssertTrue(app.buttons["settingsGearButton"].exists)
    }

    /// 点「论文 / 学术」→ 场景导入面板，列出上传文件 + 输入网址等来源。
    func testScenarioTapOpensSourcePicker() {
        let app = launchZh()
        let card = app.buttons["scenario-paper"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["输入网址"].waitForExistence(timeout: 5), "场景 Menu 未弹来源选择")
    }

    /// Kindle 模块未登录时点击「绑定 Kindle」，进入 Amazon 登录 / 同步 WebView。
    func testKindleConnectOpensWebView() {
        let app = launchZh()
        let connect = app.buttons["connectKindleButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        XCTAssertTrue(app.navigationBars["绑定 Kindle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8), "绑定 Kindle 未打开 WebView")
    }

    /// 可选真账号验收：由环境变量注入 KINDLE_EMAIL / KINDLE_PASSWORD，不把凭据写进仓库。
    func testKindleAmazonLoginAndSyncWhenCredentialsProvided() throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["KINDLE_EMAIL"], !email.isEmpty,
              let password = env["KINDLE_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("KINDLE_EMAIL / KINDLE_PASSWORD not provided")
        }

        let app = launchZh()
        let connect = app.buttons["connectKindleButton"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))

        let web = app.webViews.firstMatch
        let emailField = web.textFields.firstMatch
        if emailField.waitForExistence(timeout: 12) {
            emailField.tap()
            emailField.typeText(email)
            tapFirstExisting(in: app, labels: ["Continue", "继续", "继续登录"])
        }

        let passwordField = web.secureTextFields.firstMatch
        guard passwordField.waitForExistence(timeout: 12) else {
            throw XCTSkip("Amazon did not expose a password field, likely already signed in or waiting for verification.")
        }
        passwordField.tap()
        UIPasteboard.general.string = password
        passwordField.press(forDuration: 1.0)
        tapFirstExisting(in: app, labels: ["Paste", "粘贴"])
        tapFirstExisting(in: app, labels: ["Sign in", "Sign-In", "登录"])

        sleep(5)
        if app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "verification", "captcha", "code")).firstMatch.exists {
            throw XCTSkip("Amazon requested verification/captcha.")
        }

        let sync = app.buttons["Sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 20), "Kindle sync button not visible after login attempt")
        sync.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "synced")).firstMatch.waitForExistence(timeout: 30))
    }

    /// 设置入口放在 Voice 右上角，首页本身保持不变。
    func testVoiceSettingsGearKeepsLibraryEntry() {
        let app = launchZh()
        app.tabBars.buttons["音色"].tap()
        let settingsGear = app.buttons["settingsGearButton"].firstMatch
        XCTAssertTrue(settingsGear.waitForExistence(timeout: 5), "Voice 右上角缺设置入口")
        settingsGear.tap()
        XCTAssertTrue(app.buttons["settingsLibraryLink"].waitForExistence(timeout: 5), "设置里缺文库入口")
        XCTAssertFalse(app.tabBars.buttons["设置"].exists)
    }

    private func tapFirstExisting(in app: XCUIApplication, labels: [String]) {
        for label in labels {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.exists { returnKey.tap() }
    }
}
