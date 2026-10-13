import XCTest

/// Real public model download, scoped to an isolated simulator. Does not sign
/// in, synthesize speech, alter account state, or enable Safari site permissions.
final class OCRModelDownloadUITests: XCTestCase {
    func testPrepareFrenchAndReopenKeepsItReady() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
            "-CastReaderRegion", "global", "-CastReaderServiceRoute", "global",
            "-AppleLanguages", "(en)", "-interfaceLanguage", "en", "-auto_play", "NO"]
        func openModels() {
            app.launch()
            let tab = app.buttons["settingsGearButton"]
            XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
            tab.tap()
            let entry = app.buttons["ocrModelSettingsEntry"]
            for _ in 0..<12 {
                if entry.exists && entry.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(entry.isHittable)
            entry.tap()
            XCTAssertTrue(app.navigationBars["Recognition languages"].waitForExistence(timeout: 10))
        }
        openModels()
        XCTAssertTrue(app.images["ocrModelReady_eng"].waitForExistence(timeout: 10))
        let french = app.buttons["ocrModelDownload_fra"]
        if french.exists { french.tap() }
        let ready = app.images["ocrModelReady_fra"]
        XCTAssertTrue(ready.waitForExistence(timeout: 90), app.debugDescription)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "ocr-languages-prepared"; image.lifetime = .keepAlways; add(image)
        app.terminate()
        openModels()
        XCTAssertTrue(app.images["ocrModelReady_fra"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["ocrModelDownload_fra"].exists)
    }
}
