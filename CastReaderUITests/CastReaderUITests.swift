//
//  CastReaderUITests.swift
//  CastReaderUITests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest
import UIKit

class CastReaderUITests: XCTestCase {

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

    /// 底部中间 ➕ → 弹出快速导入面板（含「上传文件」「输入网址」等方式）。
    func testPlusOpensImportSheet() {
        let app = launchZh()
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 5))
        app.buttons["plusImportButton"].tap()
        XCTAssertTrue(app.buttons["上传文件"].waitForExistence(timeout: 5), "➕ 未弹出导入方式")
        XCTAssertTrue(app.buttons["输入网址"].exists)
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

    /// 文库已从底部 Tab 下沉到「设置」：设置页存在「文库」入口。
    func testLibraryMovedIntoSettings() {
        let app = launchZh()
        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "底部缺设置 Tab")
        settingsTab.tap()
        XCTAssertTrue(app.buttons["settingsLibraryLink"].waitForExistence(timeout: 5), "设置里缺文库入口")
        // 文库不应再是底部 Tab（底部仅 首页/占位/设置 共 3 项）
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
