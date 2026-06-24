//
//  CastReaderUITests.swift
//  CastReaderUITests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest

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
        let app = launchZh()

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
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        return app
    }

    /// 首页渲染 6 个场景入口（论文/书籍/报告/合同/教材/说明书）。
    func testHomeShowsSixScenarios() {
        let app = launchZh()
        for name in ["论文 / 学术", "书籍 / 长篇", "报告 / 研报", "合同 / 条款", "教材 / 学习", "说明书 / 文档"] {
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5), "缺场景入口: \(name)")
        }
    }

    /// 底部中间 ➕ → 弹出通用导入动作表（含「上传文件」「输入网址」等方式）。
    func testPlusOpensImportSheet() {
        let app = launchZh()
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 5))
        app.buttons["plusImportButton"].tap()
        XCTAssertTrue(app.buttons["上传文件"].waitForExistence(timeout: 5), "➕ 未弹出导入方式")
        XCTAssertTrue(app.buttons["输入网址"].exists)
    }

    /// 点「论文 / 学术」(来源 PDF/网址，多来源) → 弹出该场景的来源选择（含网址）。
    func testScenarioTapOpensSourcePicker() {
        let app = launchZh()
        app.staticTexts["论文 / 学术"].tap()
        // 多来源场景弹来源选择动作表（列出 上传文件 + 输入网址）。
        XCTAssertTrue(app.buttons["输入网址"].waitForExistence(timeout: 5), "场景未弹来源选择")
    }

    /// 文库已从底部 Tab 下沉到「设置」：设置页存在「文库」入口。
    func testLibraryMovedIntoSettings() {
        let app = launchZh()
        // 底部第三个 Tab = 设置
        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["文库"].waitForExistence(timeout: 5), "设置里缺文库入口")
        // 文库不应再是底部 Tab（底部仅 首页/占位/设置 共 3 项）
    }
}
