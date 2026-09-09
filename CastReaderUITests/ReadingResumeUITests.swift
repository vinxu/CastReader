import XCTest

final class ReadingResumeUITests: XCTestCase {
    func testPauseButtonWorksWhileSpeechIsLoadingAndLateAudioStaysPaused() {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderResumeMVPFixture", "-CastReaderResetResumeFixture",
                               "-CastReaderResumeDelayedAudio", "-CastReaderSkipSignInGate",
                               "-CastReaderSkipLibraryOnboarding"]
        app.launch()
        let start = app.buttons["resumeFixtureStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let status = app.staticTexts["resumeFixtureStatus"]
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "waiting=true"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 3), .completed)
        let button = app.buttons["readPlayPauseButton"]
        XCTAssertTrue(button.isEnabled, "Waiting for audio must not disable Pause")
        button.tap()
        let queuedPaused = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "queued=true", "userPaused=true", "playing=false"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [queuedPaused], timeout: 10), .completed)
        XCTAssertEqual(time(in: status.label), 0)
        attach(app, name: "late-audio-queued-and-paused")
        button.tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "playing=true"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 8), .completed)
        button.tap()
        app.terminate()
    }

    func testHundredChapterEPUBResumesAfterProcessTerminationBeforePlaying() {
        let app = XCUIApplication()
        let base = ["-CastReaderResumeMVPFixture", "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en"]
        app.launchArguments = base + ["-CastReaderResetResumeFixture"]
        app.launch()
        let start = app.buttons["resumeFixtureStart"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let status = app.staticTexts["resumeFixtureStatus"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "playing=true"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 12), .completed)
        // Let the real AVPlayer advance inside a segment, then pause through
        // the production playback control, not by seeding a checkpoint file.
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] object, _ in
            guard let element = object as? XCUIElement else { return false }
            return time(in: element.label) >= 4
        }, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: 9), .completed)
        app.buttons["readPlayPauseButton"].tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "playing=false"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        let before = status.label
        let stoppedTime = time(in: before)
        XCTAssertGreaterThanOrEqual(stoppedTime, 4)
        XCTAssertTrue(before.contains("paragraph=199;"), before)
        attach(app, name: "epub-100-paused")
        app.terminate()
        app.launchArguments = base
        app.launch()
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.label.contains("paragraph=199;"), status.label)
        XCTAssertTrue(status.label.contains("playing=false"), status.label)
        let destination = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "Resume destination")).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 6))
        XCTAssertTrue(destination.isHittable, "Saved paragraph must be visible before pressing Play")
        attach(app, name: "epub-100-cold-reopen-located")
        app.buttons["readPlayPauseButton"].tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@ AND NOT label CONTAINS %@", "playing=true", "time=0;", "time=1;"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 12), .completed)
        XCTAssertTrue(status.label.contains("paragraph=199;"), status.label)
        XCTAssertGreaterThanOrEqual(time(in: status.label), stoppedTime)
        XCTAssertLessThanOrEqual(time(in: status.label), stoppedTime + 3)
        attach(app, name: "epub-100-resumed-inside-segment")
        app.buttons["readPlayPauseButton"].tap()
        app.terminate()
    }


    func testUnifiedHomeLibraryAndNotificationResumeLatestStopAfterColdStart() {
        let app = XCUIApplication()
        let base = ["-CastReaderUnifiedCatalogFixture", "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en"]
        app.launchArguments = base + ["-CastReaderResetResumeFixture"]
        app.launch()
        XCTAssertTrue(app.buttons["resumeFixtureStart"].waitForExistence(timeout: 15))
        app.buttons["resumeFixtureStart"].tap()
        let status = app.staticTexts["resumeFixtureStatus"]
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] object, _ in
            guard let element = object as? XCUIElement else { return false }
            return time(in: element.label) >= 4 && element.label.contains("playing=true")
        }, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: 15), .completed)
        app.buttons["readPlayPauseButton"].tap()
        let stopped = time(in: status.label)
        app.buttons["catalogHome"].tap()
        let card = app.buttons["continue-item-catalog-mvp-100"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        for _ in 0..<4 where !card.isHittable { app.swipeUp() }
        XCTAssertTrue(card.isHittable)
        attach(app, name: "unified-home-saved-position")
        app.terminate()
        app.launchArguments = base
        app.launch()
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        for _ in 0..<4 where !card.isHittable { app.swipeUp() }
        card.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.label.contains("paragraph=199;"), status.label)
        XCTAssertTrue(status.label.contains("playing=false"), status.label)
        attach(app, name: "unified-home-cold-located")
        app.buttons["catalogLibrary"].tap()
        let row = app.buttons["library-item-catalog-mvp-100"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        attach(app, name: "unified-library-saved-position")
        row.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.label.contains("paragraph=199;"), status.label)
        XCTAssertTrue(status.label.contains("playing=false"), status.label)
        app.buttons["catalogHome"].tap()
        app.buttons["catalogSettings"].tap()
        let libraryLink = app.buttons["settingsLibraryLink"].firstMatch
        XCTAssertTrue(libraryLink.waitForExistence(timeout: 10))
        for _ in 0..<5 where !libraryLink.isHittable { app.swipeUp() }
        libraryLink.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.isHittable, "Settings must close so the resumed reader is actually visible")
        XCTAssertFalse(app.buttons["settingsCloseButton"].exists)
        XCTAssertTrue(status.label.contains("paragraph=199;"), status.label)
        attach(app, name: "unified-settings-library-dismissed-and-located")
        app.buttons["catalogHome"].tap()
        app.buttons["catalogNotification"].tap()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.label.contains("playing=true") && time(in: element.label) >= stopped
        }, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 15), .completed)
        XCTAssertTrue(status.label.contains("paragraph=199;"), status.label)
        XCTAssertLessThanOrEqual(time(in: status.label), stopped + 3)
        attach(app, name: "unified-notification-actual-resume")
        app.buttons["readPlayPauseButton"].tap()
        app.terminate()
    }

    private func time(in label: String) -> Int {
        let field = label.split(separator: ";").first { $0.hasPrefix("time=") }
        return field.flatMap { Int($0.dropFirst(5)) } ?? -1
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
