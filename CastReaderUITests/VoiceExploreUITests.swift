import XCTest

final class VoiceExploreUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private let publicID = "vl_083fdead97ec221573f3"
    private func launch(_ language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderVoiceExploreFixture", "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-AppleLanguages", "(\(language))", "-interfaceLanguage", language]
        app.launchEnvironment["CASTREADER_VOICE_FIXTURE_DIRECTORY"] = Bundle(for: Self.self).resourceURL!.appendingPathComponent("VoiceDiscovery").path
        app.launch()
        return app
    }

    func testWeeklyCollectionPreviewFavoriteAndLanguageIdentity() {
        let app = launch()
        let weekly = app.descendants(matching: .any).matching(identifier: "voiceEdition_weekly-stories").firstMatch
        XCTAssertTrue(weekly.waitForExistence(timeout: 20))
        attach(app, "voice-discovery-feed-en")
        weekly.tap()
        let preview = app.buttons["voicePreview_\(publicID)"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        let playing = NSPredicate(format: "value ==[c] %@", "playing")
        expectation(for: playing, evaluatedWith: preview)
        waitForExpectations(timeout: 10)
        preview.tap()
        app.buttons["voiceFavorite_\(publicID)"].tap()
        app.buttons["voiceQuota_\(publicID)"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 hours per month")).firstMatch.exists)
        attach(app, "voice-discovery-monthly-allowance")
        app.alerts.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.segmentedControls.buttons["Favorites"].tap()
        XCTAssertTrue(app.buttons["presetVoiceSelect_\(publicID)"].waitForExistence(timeout: 5))
        app.buttons["Language"].tap()
        let search = app.searchFields["Search Languages"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Chinese")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chinese")).firstMatch.tap()
        XCTAssertTrue(app.buttons["presetVoiceSelect_\(publicID)"].waitForExistence(timeout: 5))
        attach(app, "voice-discovery-favorite-chinese")
    }

    func testCompactChineseHeaderAndSearch() {
        let app = launch("zh-Hans")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "voiceEdition_weekly-stories").firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["常规音色 · Pro 不限时"].exists)
        XCTAssertFalse(app.staticTexts["按成功生成的音频时长计量；试听和重复播放已生成的音频不扣额度。"].exists)
        attach(app, "voice-discovery-feed-zh")
        app.swipeUp()
        attach(app, "voice-discovery-categories-zh")
        XCTAssertTrue(app.buttons["voiceTopic_everyday"].waitForExistence(timeout: 5))
        app.buttons["voiceTopic_everyday"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Heart")
        XCTAssertTrue(app.buttons["presetVoiceSelect_af_heart"].waitForExistence(timeout: 5))
        attach(app, "voice-discovery-topic-search")
        app.buttons["presetVoiceSelect_af_heart"].tap()
        XCTAssertEqual(app.buttons["presetVoiceSelect_af_heart"].value as? String, "已选择")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
