import XCTest

/// Explicitly selected only on the simulator the user has signed into Kindle.
/// Never signs in, clears a shelf or copies WebKit credentials.
final class KindleLiveAcceptanceUITests: XCTestCase {
    private func wait(_ timeout: Double, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let app = XCUIApplication()
            // The authorized account can have another device's saved location.
            // Keep this test's current page through Amazon's visible native UI.
            if app.staticTexts["Most Recent Page Read"].exists {
                let keepCurrentPage = app.buttons["No"]
                if keepCurrentPage.isHittable { keepCurrentPage.tap() }
            }
            return condition()
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func tapFootnoteSwitch(_ app: XCUIApplication) {
        let row = app.switches["kindleSkipFootnotes"]
        let control = row.descendants(matching: .switch).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if control.isHittable,
               control.frame.minY >= app.navigationBars.firstMatch.frame.maxY,
               control.frame.maxY <= app.frame.maxY - 44 { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(control.isHittable)
        control.tap()
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state == .runningForeground { snapshot(app, "Kindle-live-at-teardown") }
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testAuthorizedKindleReadTurnSettingsMinimizeAndRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1",
                          "Live acceptance requires the user's authorized Kindle session")
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                               "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kindle.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "Use the already authorized, synced Kindle shelf")
        for _ in 0..<6 where !book.isHittable { app.swipeUp() }
        XCTAssertTrue(book.isHittable)
        let bookID = book.identifier
        book.tap()
        let play = app.buttons["kindleReadPlayPauseButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        wait(60) { play.isEnabled }
        snapshot(app, "Kindle-live-initial-page")
        play.tap()
        wait(90) { play.value as? String == "Playing" }
        let surface = app.otherElements["kindleAcceptanceState"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let initial = surface.value as? String
        XCTAssertFalse(initial?.contains("page=none") ?? true)
        snapshot(app, "Kindle-live-playing-before-turn")

        for number in 1...3 {
            let before = surface.value as? String
            let next = app.buttons["kindleNextPageButton"]
            wait(30) { next.isHittable }
            next.tap()
            wait(60) { (surface.value as? String).map { $0 != "page=none" && $0 != before } == true && play.value as? String == "Playing" }
            snapshot(app, "Kindle-live-next-\(number)")
        }
        let beforePrevious = surface.value as? String
        let previous = app.buttons["kindlePreviousPageButton"]
        wait(30) { previous.isHittable }
        previous.tap()
        wait(60) { (surface.value as? String).map { $0 != "page=none" && $0 != beforePrevious } == true && play.value as? String == "Playing" }
        snapshot(app, "Kindle-live-previous")

        XCUIDevice.shared.orientation = .landscapeLeft
        wait(30) { app.frame.width > app.frame.height && app.buttons["pause.circle.fill"].isHittable }
        XCTAssertLessThanOrEqual(surface.frame.maxY, app.buttons["pause.circle.fill"].frame.minY,
                                 "The landscape playback bar must not cover the Kindle page")
        snapshot(app, "Kindle-live-landscape")
        XCUIDevice.shared.orientation = .portrait
        wait(30) { app.frame.height > app.frame.width && play.isHittable }
        wait(90) { play.value as? String == "Playing" }
        snapshot(app, "Kindle-live-portrait-restored")

        let readingSettings = app.buttons["kindleReadingSettingsButton"]
        wait(60) { readingSettings.isEnabled && readingSettings.isHittable }
        readingSettings.tap()
        let font = app.staticTexts["kindleFontValue"]
        XCTAssertTrue(font.waitForExistence(timeout: 15))
        wait(15) { font.label != "—" }
        let initialFont = font.label
        let increase = app.buttons["kindleFontIncrease"]
        let decrease = app.buttons["kindleFontDecrease"]
        wait(10) { increase.isEnabled || decrease.isEnabled }
        let increasing = increase.isEnabled
        (increasing ? increase : decrease).tap()
        wait(15) { font.label != initialFont && !app.activityIndicators.firstMatch.exists }
        let changedFont = font.label
        let skip = app.switches["kindleSkipFootnotes"]
        let initialSkip = skip.value as? String
        tapFootnoteSwitch(app)
        wait(5) { skip.value as? String != initialSkip }
        snapshot(app, "Kindle-live-settings-changed")
        app.buttons["kindleReadingSettingsDone"].tap()
        wait(15) { play.value as? String == "Paused" }
        play.tap()
        wait(90) { play.value as? String == "Playing" }

        var hiddenPage = surface.value as? String
        XCTAssertNotNil(hiddenPage)
        XCTAssertNotEqual(hiddenPage, "page=none")
        app.buttons["kindleMinimizeButton"].tap()
        let expand = app.descendants(matching: .any)["kindleMiniPlayerExpand"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        let hiddenSurface = app.otherElements["kindleMiniAcceptanceState"]
        XCTAssertTrue(hiddenSurface.waitForExistence(timeout: 10))
        snapshot(app, "Kindle-live-mini-player")
        // The state contains only a page hash. Two actual hidden automatic
        // turns are required; changing paragraphs or playback flags cannot pass.
        for _ in 0..<2 {
            wait(180) {
                guard let page = hiddenSurface.value as? String, page != "page=none" else { return false }
                return page != hiddenPage
            }
            hiddenPage = hiddenSurface.value as? String
        }
        expand.tap()
        wait(30) { play.value as? String == "Playing" }
        snapshot(app, "Kindle-live-expanded")
        play.tap()
        wait(10) { play.value as? String == "Paused" }
        app.terminate()
        app.launch()
        let restoredBook = app.buttons[bookID]
        XCTAssertTrue(restoredBook.waitForExistence(timeout: 20))
        for _ in 0..<6 where !restoredBook.isHittable { app.swipeUp() }
        restoredBook.tap()
        XCTAssertTrue(app.buttons["kindleReadingSettingsButton"].waitForExistence(timeout: 60))
        wait(60) { readingSettings.isEnabled && readingSettings.isHittable }
        readingSettings.tap()
        // A late Amazon position dialog may preempt the native settings
        // sheet. The wait helper chooses No in Amazon's visible UI; only
        // then may this explicit settings request be repeated.
        wait(60) {
            if !app.buttons["kindleReadingSettingsDone"].exists,
               !app.staticTexts["Most Recent Page Read"].exists {
                let settings = app.buttons["kindleReadingSettingsButton"]
                if settings.isHittable && settings.isEnabled { settings.tap() }
            }
            return font.exists && font.label == changedFont
        }
        XCTAssertNotEqual(skip.value as? String, initialSkip)
        snapshot(app, "Kindle-live-settings-persisted-after-relaunch")
        // A retry can restore the known pre-test preferences from a previous
        // interrupted run, while a normal run restores its own initial values.
        let restoreFont = ProcessInfo.processInfo.environment["CASTREADER_TEST_RESTORE_KINDLE_FONT"] ?? initialFont
        let restoreSkip = ProcessInfo.processInfo.environment["CASTREADER_TEST_RESTORE_KINDLE_SKIP"] ?? initialSkip
        for _ in 0..<12 where font.label != restoreFont {
            let current = try XCTUnwrap(Double(font.label))
            let target = try XCTUnwrap(Double(restoreFont))
            let before = font.label
            (current > target ? decrease : increase).tap()
            wait(15) { font.label != before && !app.activityIndicators.firstMatch.exists }
        }
        XCTAssertEqual(font.label, restoreFont)
        if skip.value as? String != restoreSkip { tapFootnoteSwitch(app) }
        wait(5) { skip.value as? String == restoreSkip }
        app.buttons["kindleReadingSettingsDone"].tap()
        snapshot(app, "Kindle-live-acceptance-complete")
        app.buttons["kindleMinimizeButton"].tap()
        let settings = app.buttons["settingsGearButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let version = app.descendants(matching: .any)["settingsAppVersion"].firstMatch
        for _ in 0..<8 where !version.isHittable { app.swipeUp() }
        XCTAssertTrue(version.isHittable)
        let expectedVersion = try XCTUnwrap(ProcessInfo.processInfo.environment["CASTREADER_TEST_APP_VERSION"])
        XCTAssertTrue(app.staticTexts[expectedVersion].exists, "Settings must show the installed app's actual version and build")
        snapshot(app, "Kindle-live-app-version")
        app.buttons["settingsCloseButton"].tap()
    }
}
