import XCTest

final class VoiceExploreUITests: XCTestCase {
    func testCuratedVoiceAndQuotaSurviveLanguageSwitchAndFavorites() {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderVoiceExploreFixture", "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceGenerationQuotaSummary").firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["presetVoiceSelect_vl_rowan"].value as? String == "Selected")
        attach(app, "voice-explore-english")
        app.buttons["Language"].tap()
        let search = app.searchFields["Search Languages"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Chinese")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chinese")).firstMatch.tap()
        XCTAssertTrue(app.buttons["presetVoiceSelect_vl_rowan"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["presetVoiceSelect_vl_rowan"].value as? String, "Selected")
        XCTAssertTrue(app.buttons["presetVoiceSelect_vl_rowan"].exists)
        attach(app, "voice-explore-chinese-content")
        app.buttons["voiceFavorite_vl_rowan"].tap()
        app.segmentedControls.buttons["Favorites"].tap()
        XCTAssertTrue(app.buttons["presetVoiceSelect_vl_rowan"].exists)
        XCTAssertTrue(app.buttons["presetVoiceSelect_vl_rowan"].label.contains("Shared monthly allowance"))
    }

    func testCompactChineseHeader() {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderVoiceExploreFixture", "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-interfaceLanguage", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.staticTexts["精选音色"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["常规音色 · Pro 不限时"].exists)
        XCTAssertFalse(app.staticTexts["按成功生成的音频时长计量；试听和重复播放已生成的音频不扣额度。"].exists)
        attach(app, "voice-explore-compact-zh")
        app.buttons["额度说明"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "试听和重复播放")).firstMatch.exists)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
