import XCTest
import UIKit

/// Run against an iPad destination. Screenshots use the actual production
/// surfaces; only the existing Debug login/onboarding bypass is enabled.
final class iPadAdaptationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func home(_ language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
            "-CastReaderRegion", "global", "-AppleLanguages", "(\(language))",
            "-AppleLocale", "en_US", "-interfaceLanguage", language]
        app.launch()
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 30))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func rotate(_ app: XCUIApplication, _ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let landscape = orientation.isLandscape
        let predicate = NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > 0 && (landscape ? frame.width > frame.height : frame.height > frame.width)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: 10), .completed)
        dismissRatingIfPresent(app)
    }

    private func dismissRatingIfPresent(_ app: XCUIApplication) {
        // A real account may have earned the system review prompt. Dismiss it
        // without submitting a rating or changing the account's stored state.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app, springboard] {
            let later = owner.buttons["Not Now"].firstMatch
            if later.exists && later.isHittable { later.tap() }
        }
    }

    func testUniversalNavigationAndAllOrientations() {
        let app = home()
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"),
            (.landscapeLeft, "landscape-left"), (.landscapeRight, "landscape-right"),
            (.portraitUpsideDown, "portrait-upside-down")] {
            rotate(app, orientation)
            XCTAssertTrue(app.buttons["plusImportButton"].isHittable)
            capture(app, "module1-home-\(name)")
        }
        rotate(app, .portrait)
        for title in ["Library", "Voice", "Settings", "Home"] {
            let tab = app.buttons[title].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "Missing iPad navigation: \(title)")
            XCTAssertTrue(tab.isHittable)
            tab.tap()
            capture(app, "module1-\(title)-portrait")
            rotate(app, .landscapeLeft)
            capture(app, "module1-\(title)-landscape")
            rotate(app, .portrait)
        }
        app.buttons["plusImportButton"].tap()
        capture(app, "module1-import-portrait")
        rotate(app, .landscapeLeft)
        capture(app, "module1-import-landscape")
    }

    func testNativeTextRotation() { verifyReaderRotation("text-long") }
    func testNativeEPUBRotation() { verifyReaderRotation("epub-long") }
    func testNativePDFRotation() { verifyReaderRotation("pdf") }
    func testNativeScannedPDFRotation() { verifyReaderRotation("pdf-ocr") }
    func testNativePhotoRotation() { verifyReaderRotation("photo") }
    func testNativeDOCXRotation() { verifyReaderRotation("docx-long") }
    func testNativeWebRotation() { verifyReaderRotation("web-long") }
    func testYouTubeTranscriptRotation() { verifyReaderRotation("youtube-long") }

    private func number(_ key: String, in text: String) -> Double {
        text.split(separator: ";").first { $0.hasPrefix(key + "=") }
            .flatMap { Double($0.dropFirst(key.count + 1)) } ?? -1
    }

    private func waitForStatus(_ status: XCUIElement, timeout: TimeInterval = 20,
                               _ matches: @escaping (String) -> Bool) -> Bool {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && matches(status.label)
        }, object: status)
        return XCTWaiter.wait(for: [expected], timeout: timeout) == .completed
    }

    private func scenario(_ kind: String) -> XCUIApplication {
        let app = XCUIApplication()
        // These fixtures use isolated document/progress directories. They do
        // not remove the signed-in account, Kindle cookies or real library.
        app.launchArguments = ["-CastReaderResumeScenario", kind, "-CastReaderResetResumeScenario",
            "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-CastReaderForceDebugPro",
            "-auto_play", "NO", "-tts_speed", "1", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-interfaceLanguage", "en"]
        app.launch()
        return app
    }

    func testPDFManualZoomAndPositionSurviveRotation() {
        let app = scenario("pdf")
        let status = app.staticTexts["scenarioStatus"]
        XCTAssertTrue(waitForStatus(status, timeout: 45) { self.number("target", in: $0) >= 0 })
        app.buttons["scenarioSeekTarget"].tap()
        XCTAssertTrue(waitForStatus(status) { $0.contains("playing=true") })
        app.buttons["readPlayPauseButton"].tap()
        app.buttons["scenarioFollowOff"].tap()
        let canvas = app.descendants(matching: .any)["pdfReaderCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        capture(app, "module2-pdf-before-pinch")
        canvas.pinch(withScale: 2, velocity: 1)
        capture(app, "module2-pdf-after-pinch")
        XCTAssertTrue(waitForStatus(status) { self.number("zoom", in: $0) > 1.2 }, status.label)
        canvas.swipeUp()
        canvas.swipeUp()
        XCTAssertTrue(waitForStatus(status) { self.number("centerPage", in: $0) >= 0 })
        let page = number("centerPage", in: status.label)
        let centerY = number("centerY", in: status.label)
        let zoom = number("zoom", in: status.label)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            rotate(app, orientation)
            XCTAssertTrue(waitForStatus(status) { $0.contains("layoutStable=true") && abs(self.number("zoom", in: $0) - zoom) < 0.08 })
            XCTAssertEqual(number("centerPage", in: status.label), page, "Manual browsing must keep its page")
            XCTAssertEqual(number("centerY", in: status.label), centerY, accuracy: 10, "Rotation must keep the same page point in the viewport center")
            capture(app, "module2-pdf-manual-\(orientation.rawValue)")
        }
        canvas.pinch(withScale: 0.6, velocity: -1)
        XCTAssertTrue(waitForStatus(status) { self.number("zoom", in: $0) < zoom - 0.2 })
        capture(app, "module2-pdf-zoom-out")
        app.terminate()
    }

    private func verifyReaderRotation(_ kind: String) {
        let app = scenario(kind)
        let status = app.staticTexts["scenarioStatus"]
        XCTAssertTrue(waitForStatus(status, timeout: 45) { self.number("target", in: $0) >= 0 })
        let target = number("target", in: status.label)
        app.buttons["scenarioSeekTarget"].tap()
        XCTAssertTrue(waitForStatus(status) { $0.contains("playing=true") && self.number("time", in: $0) >= 1 })
        app.buttons["readPlayPauseButton"].tap()
        XCTAssertTrue(waitForStatus(status) { $0.contains("playing=false") })
        let stopped = number("time", in: status.label)
        let segment = number("segment", in: status.label)
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"),
            (.landscapeLeft, "landscape-left"), (.landscapeRight, "landscape-right"),
            (.portraitUpsideDown, "portrait-upside-down"), (.portrait, "portrait-restored")] {
            rotate(app, orientation)
            XCTAssertTrue(waitForStatus(status) {
                $0.contains("layoutStable=true") && ($0.contains("activeVisible=true") || $0.contains("visible=true"))
            }, "\(kind) lost its reading anchor: \(status.label)")
            XCTAssertEqual(number("paragraph", in: status.label), target)
            XCTAssertEqual(number("segment", in: status.label), segment)
            XCTAssertEqual(number("time", in: status.label), stopped, accuracy: 0.4)
            XCTAssertTrue(app.buttons["readPlayPauseButton"].isHittable)
            capture(app, "module2-\(kind)-\(name)")
        }
        if kind == "pdf" {
            let canvas = app.descendants(matching: .any)["pdfReaderCanvas"].firstMatch
            canvas.pinch(withScale: 2, velocity: 1)
            XCTAssertTrue(waitForStatus(status) { self.number("zoom", in: $0) > 1.2 })
            let zoom = number("zoom", in: status.label)
            rotate(app, .landscapeLeft)
            XCTAssertTrue(waitForStatus(status) { $0.contains("activeVisible=true") && abs(self.number("zoom", in: $0) - zoom) < 0.08 })
            capture(app, "module2-pdf-zoom-follow-word")
            canvas.pinch(withScale: 0.5, velocity: -1)
        }
        if kind == "photo" {
            let canvas = app.scrollViews["photoReaderCanvas"]
            canvas.pinch(withScale: 2, velocity: 1)
            XCTAssertTrue(waitForStatus(status) { self.number("zoom", in: $0) > 1.2 })
            let zoom = number("zoom", in: status.label)
            rotate(app, .landscapeLeft)
            XCTAssertTrue(waitForStatus(status) { $0.contains("layoutStable=true") && abs(self.number("zoom", in: $0) - zoom) < 0.02 })
            capture(app, "module2-photo-zoom-preserved")
            canvas.doubleTap()
        }
        if kind == "youtube-long" {
            app.buttons["readerMinimizeButton"].tap()
            rotate(app, .landscapeLeft)
            app.buttons["scenarioExpand"].tap()
            XCTAssertTrue(waitForStatus(status) { $0.contains("activeVisible=true") || $0.contains("visible=true") })
            capture(app, "module3-youtube-expanded-landscape")
            app.terminate()
            return
        }
        app.buttons["scenarioShowMarks"].tap()
        XCTAssertTrue(waitForStatus(status) { self.number("marks", in: $0) == 1 && $0.contains("visible=true") })
        let markID = status.label.split(separator: ";").first { $0.hasPrefix("markID=") }.map(String.init) ?? "missing"
        for (orientation, name) in [(UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait")] {
            rotate(app, orientation)
            XCTAssertTrue(waitForStatus(status) { $0.contains("layoutStable=true") && $0.contains("visible=true") })
            XCTAssertTrue(status.label.contains(markID), "Resize must keep the same explanation mark")
            capture(app, "module2-\(kind)-explain-\(name)")
        }
        app.terminate()
    }
}
