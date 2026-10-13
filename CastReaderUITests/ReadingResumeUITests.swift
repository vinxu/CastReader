import XCTest

final class ReadingResumeUITests: XCTestCase {
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
