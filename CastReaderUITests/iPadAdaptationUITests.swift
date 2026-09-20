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
}
