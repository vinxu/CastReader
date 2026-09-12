import XCTest

final class SleepTimerUITests: XCTestCase {
    private func launch(systemLanguage: String = "en", interfaceLanguage: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSleepTimerFixture", "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-AppleLanguages", "(\(systemLanguage))", "-AppleLocale", systemLanguage == "en" ? "en_US" : "zh_CN", "-interfaceLanguage", interfaceLanguage]
        app.launch()
        XCTAssertTrue(app.buttons["readerMoreButton"].waitForExistence(timeout: 20))
        return app
    }

    func testMoreMenuTimerAndAppearance() {
        let app = launch()
        app.buttons["readerMoreButton"].tap()
        let appearance = app.buttons["readerAppearanceMenuItem"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertEqual(appearance.label, "Reading settings")
        attach(app, "reader-more-native-icons")
        app.buttons["readerSleepTimerMenuItem"].tap()
        XCTAssertTrue(app.buttons["sleepTimerPreset.15"].waitForExistence(timeout: 5))
        attach(app, "sleep-timer-options")
        app.buttons["sleepTimerPreset.15"].tap()
        wait(app, contains: "active=true")
        app.buttons["readerMoreButton"].tap()
        app.buttons["readerSleepTimerMenuItem"].tap()
        XCTAssertTrue(app.staticTexts["sleepTimerCountdown"].waitForExistence(timeout: 5))
        attach(app, "sleep-timer-active")
        app.buttons["sleepTimerCancel"].tap()
        wait(app, contains: "active=false")
        app.buttons["readerMoreButton"].tap()
        app.buttons["readerAppearanceMenuItem"].tap()
        XCTAssertTrue(app.buttons["readerTextSizeIncrease"].waitForExistence(timeout: 5))
        let before = app.staticTexts["readerTextSizeValue"].label
        app.buttons["readerTextSizeIncrease"].tap()
        XCTAssertNotEqual(app.staticTexts["readerTextSizeValue"].label, before)
        attach(app, "reader-appearance")
        app.swipeUp()
        XCTAssertTrue(app.buttons["readerAppearanceReset"].waitForExistence(timeout: 5))
        app.buttons["readerAppearanceReset"].tap()
        app.buttons["readerSettingsDone"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["readerMoreButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["readerMoreButton"].isHittable)
        attach(app, "reader-more-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testMoreMenuIconsWithChineseSystemAndEnglishInterface() {
        // Match the user's mixed-language phone; English-only QA missed the
        // old textformat symbol turning into the Chinese word “格式”.
        let app = launch(systemLanguage: "zh-Hans")
        app.buttons["readerMoreButton"].tap()
        let appearance = app.buttons["readerAppearanceMenuItem"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertEqual(appearance.label, "Reading settings")
        XCTAssertTrue(app.buttons["readerSleepTimerMenuItem"].isHittable)
        attach(app, "reader-more-pictographic-icons-chinese-system")
        appearance.tap()
        XCTAssertTrue(app.buttons["readerTextSizeIncrease"].waitForExistence(timeout: 5))
        app.buttons["readerSettingsDone"].tap()
        app.terminate()
    }

    func testMoreTimerAndAppearanceInAllNineInterfaceLanguages() {
        continueAfterFailure = false
        let labels = [
            ("en", "Reading settings", "Sleep Timer"),
            ("zh-Hans", "阅读设置", "定时停止"),
            ("ja", "読書設定", "スリープタイマー"),
            ("es", "Ajustes de lectura", "Temporizador"),
            ("fr", "Réglages de lecture", "Minuteur de veille"),
            ("de", "Leseeinstellungen", "Sleep-Timer"),
            ("pt-BR", "Configurações de leitura", "Temporizador"),
            ("it", "Impostazioni di lettura", "Timer di spegnimento"),
            ("hi", "पढ़ने की सेटिंग", "स्लीप टाइमर")
        ]
        for (language, settingsTitle, timerTitle) in labels {
            let app = launch(systemLanguage: "zh-Hans", interfaceLanguage: language)
            app.buttons["readerMoreButton"].tap()
            let settings = app.buttons["readerAppearanceMenuItem"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            XCTAssertEqual(settings.label, settingsTitle)
            XCTAssertEqual(app.buttons["readerSleepTimerMenuItem"].label, timerTitle)
            attach(app, "reader-more-\(language)")
            settings.tap()
            XCTAssertTrue(app.buttons["readerTextSizeIncrease"].waitForExistence(timeout: 5))
            attach(app, "reader-settings-\(language)")
            app.buttons["readerSettingsDone"].tap()
            app.buttons["readerMoreButton"].tap()
            app.buttons["readerSleepTimerMenuItem"].tap()
            XCTAssertTrue(app.buttons["sleepTimerPreset.15"].waitForExistence(timeout: 5))
            attach(app, "sleep-timer-\(language)")
            let customMode = app.segmentedControls["sleepTimerCustomMode"]
            for _ in 0..<3 {
                if customMode.exists && customMode.isHittable { break }
                app.collectionViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(customMode.isHittable)
            customMode.buttons.element(boundBy: 1).tap()
            XCTAssertTrue(app.datePickers["sleepTimerStopTimePicker"].waitForExistence(timeout: 5))
            attach(app, "sleep-timer-stop-time-\(language)")
            XCTAssertTrue(app.buttons["sleepTimerStartCustom"].isHittable)
            app.buttons["readerSettingsDone"].tap()
            app.terminate()
        }
    }

    func testReadExpiresAndResumesAtSavedPosition() {
        let app = launch()
        app.buttons["sleepFixtureRead"].tap()
        wait(app, contains: "playing=true")
        app.buttons["sleepFixtureShortTimer"].tap()
        wait(app, contains: "expired=true", timeout: 10)
        wait(app, contains: "playing=false")
        let stopped = seconds(app)
        XCTAssertGreaterThan(stopped, 0)
        attach(app, "read-sleep-timer-expired")
        app.buttons["readPlayPauseButton"].tap()
        wait(app, contains: "playing=true")
        XCTAssertGreaterThanOrEqual(seconds(app), stopped)
        app.buttons["sleepFixtureBackgroundTimer"].tap()
        app.buttons["sleepFixtureClose"].tap()
        wait(app, contains: "active=false")
        app.terminate()
    }

    func testExplainTimerExpiresWhileAppIsBackgrounded() {
        let app = launch()
        app.buttons["sleepFixtureExplain"].tap()
        wait(app, contains: "playing=true")
        XCTAssertTrue(app.buttons["readerMoreButton"].isHittable)
        app.buttons["sleepFixtureBackgroundTimer"].tap()
        XCUIDevice.shared.press(.home)
        // Let the normal background-audio run loop reach the deadline.
        let delay = expectation(description: "background deadline")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { delay.fulfill() }
        wait(for: [delay], timeout: 12)
        app.activate()
        wait(app, contains: "expired=true")
        wait(app, contains: "playing=false")
        let stopped = seconds(app)
        XCTAssertLessThan(stopped, 13, "Playback must stop near the background deadline, before foreground activation")
        attach(app, "explain-background-expired")
        app.buttons["explainPlayPauseButton"].tap()
        wait(app, contains: "playing=true")
        app.terminate()
    }

    private func wait(_ app: XCUIApplication, contains value: String, timeout: TimeInterval = 10) {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", value), object: app.staticTexts["sleepFixtureStatus"])
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: timeout), .completed)
    }

    private func seconds(_ app: XCUIApplication) -> Int {
        app.staticTexts["sleepFixtureStatus"].label.split(separator: ";")
            .first { $0.hasPrefix("time=") }.flatMap { Int($0.dropFirst(5)) } ?? -1
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
