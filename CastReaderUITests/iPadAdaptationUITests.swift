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

    private func home(_ language: String = "en", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
            "-CastReaderRegion", "global", "-AppleLanguages", "(\(language))",
            "-AppleLocale", "en_US", "-interfaceLanguage", language, "-auto_play", "NO"] + extra
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

    private func selectTab(_ title: String, app: XCUIApplication) {
        // The iPadOS adaptable sidebar exposes cells; its top tab bar exposes buttons.
        let button = app.buttons[title].firstMatch
        let cell = app.cells.matching(NSPredicate(format: "label == %@", title)).firstMatch
        if button.exists && button.isHittable { button.tap() }
        else {
            XCTAssertTrue(cell.waitForExistence(timeout: 10))
            XCTAssertTrue(cell.isHittable)
            cell.tap()
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
            selectTab(title, app: app)
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

    private func importSource(_ kind: String, app: XCUIApplication) {
        app.buttons["plusImportButton"].tap()
        let source = app.buttons["importSource.\(kind)"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        for _ in 0..<5 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.isHittable)
        source.tap()
    }

    func testImportDraftsSurviveKeyboardAndRotation() {
        let app = home()
        importSource("text", app: app)
        let title = app.textFields["importTextTitle"]
        let body = app.textViews["importTextBody"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText("iPad draft")
        body.tap(); body.typeText("A reading draft stays in this window during rotation.")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            rotate(app, orientation)
            XCTAssertEqual(title.value as? String, "iPad draft")
            XCTAssertTrue((body.value as? String ?? "").contains("stays in this window"))
            XCTAssertTrue(app.buttons["Cancel"].firstMatch.isHittable)
            capture(app, "module4-text-keyboard-\(orientation.rawValue)")
        }
        app.buttons["Cancel"].firstMatch.tap()
        importSource("url", app: app)
        let url = app.textFields["importURLField"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.tap(); url.typeText("https://example.com/ipad-draft")
        rotate(app, .landscapeLeft)
        XCTAssertEqual(url.value as? String, "https://example.com/ipad-draft")
        capture(app, "module4-url-keyboard-landscape")
        app.buttons["Cancel"].firstMatch.tap()
        rotate(app, .portrait)
        importSource("file", app: app)
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        rotate(app, .landscapeLeft)
        capture(app, "module4-files-landscape")
        app.buttons["Cancel"].firstMatch.tap()
        app.terminate()
    }

    func testReaderPopoverAndVoicePanelRotation() {
        let app = scenario("text-long")
        let more = app.buttons["readerMoreButton"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(app, orientation)
            more.tap(); app.buttons["readerSleepTimerMenuItem"].tap()
            let preset = app.buttons["sleepTimerPreset.15"]
            XCTAssertTrue(preset.waitForExistence(timeout: 5))
            XCTAssertTrue(preset.isHittable)
            XCTAssertLessThan(preset.frame.width, 500)
            capture(app, "module4-timer-popover-\(orientation.rawValue)")
            app.buttons["readerSettingsDone"].tap()
            more.tap(); app.buttons["readerAppearanceMenuItem"].tap()
            XCTAssertTrue(app.buttons["readerTextSizeIncrease"].waitForExistence(timeout: 5))
            capture(app, "module4-appearance-popover-\(orientation.rawValue)")
            app.buttons["readerSettingsDone"].tap()
        }
        app.buttons["Playback Speed"].tap()
        XCTAssertTrue(app.buttons["1.5x"].waitForExistence(timeout: 5))
        capture(app, "module4-speed-landscape")
        app.buttons["1.5x"].tap()
        app.buttons["scenarioSeekTarget"].tap()
        let playback = app.staticTexts["scenarioStatus"]
        XCTAssertTrue(waitForStatus(playback) { $0.contains("playing=true") })
        app.buttons["readPlayPauseButton"].tap()
        XCTAssertTrue(app.buttons["playbackVoiceButton"].waitForExistence(timeout: 10))
        app.buttons["playbackVoiceButton"].tap()
        XCTAssertTrue(app.buttons["playbackVoiceDoneButton"].waitForExistence(timeout: 10))
        capture(app, "module4-player-voice-landscape")
        let search = app.textFields["voiceSearchField"]
        search.tap(); search.typeText("Heart")
        rotate(app, .portrait)
        XCTAssertEqual(search.value as? String, "Heart")
        XCTAssertTrue(app.buttons["playbackVoiceDoneButton"].isHittable)
        capture(app, "module4-player-voice-keyboard-portrait")
        rotate(app, .landscapeLeft)
        XCTAssertTrue(app.buttons["playbackVoiceDoneButton"].isHittable)
        capture(app, "module4-player-voice-keyboard-landscape")
        XCTAssertLessThan(search.frame.maxY, app.keyboards.firstMatch.frame.minY)
        search.typeText("\n")
        let result = app.buttons["presetVoiceSelect_af_heart"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.isHittable)
        capture(app, "module4-player-voice-search-result-landscape")
        app.buttons["playbackVoiceDoneButton"].tap()
        app.terminate()
        let live = home()
        selectTab("Voice", app: live)
        XCTAssertTrue(live.textFields["voiceSearchField"].waitForExistence(timeout: 20))
        rotate(live, .landscapeLeft)
        capture(live, "module4-voice-wide")
        live.textFields["voiceSearchField"].tap()
        live.textFields["voiceSearchField"].typeText("Heart")
        rotate(live, .portrait)
        XCTAssertEqual(live.textFields["voiceSearchField"].value as? String, "Heart")
        capture(live, "module4-voice-search-keyboard")
        live.terminate()
    }

    func testRecordingIntroductionAndControlsInLandscape() {
        let app = home(extra: ["-CastReaderOpenVoiceCloneCreation"])
        selectTab("Voice", app: app)
        XCTAssertTrue(app.buttons["My Voices"].waitForExistence(timeout: 10))
        app.buttons["My Voices"].tap()
        let confirm = app.buttons["voiceCloneIntroConfirmButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        rotate(app, .landscapeLeft)
        for _ in 0..<5 where !confirm.isHittable { app.swipeUp() }
        XCTAssertTrue(confirm.isHittable)
        capture(app, "module4-recording-intro-landscape")
        confirm.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [springboard, app] {
            let allow = owner.buttons["Allow"].firstMatch
            if allow.waitForExistence(timeout: 2) && allow.isHittable { allow.tap() }
        }
        let hold = app.descendants(matching: .any)["voiceCloneHoldButton"].firstMatch
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        for _ in 0..<5 where !hold.isHittable { app.swipeUp() }
        XCTAssertTrue(hold.isHittable)
        capture(app, "module4-recording-controls-landscape")
        rotate(app, .portrait)
        XCTAssertTrue(hold.exists)
        capture(app, "module4-recording-controls-portrait")
        app.buttons["Cancel"].firstMatch.tap()
        app.terminate()
    }

    func testPhotoPickerAndCameraFallbackRotateAndCancel() {
        let app = home()
        for source in ["photoLibrary", "camera"] {
            importSource(source, app: app)
            XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Photos"].firstMatch.waitForExistence(timeout: 20))
            capture(app, "module4-\(source)-portrait")
            rotate(app, .landscapeLeft)
            XCTAssertTrue(app.buttons["Cancel"].firstMatch.isHittable)
            capture(app, "module4-\(source)-landscape")
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 10))
            rotate(app, .portrait)
        }
        app.terminate()
    }

    func testPublicPhotoImportsIntoRotatableReader() {
        let app = home()
        importSource("photoLibrary", app: app)
        rotate(app, .landscapeLeft)
        XCTAssertTrue(app.staticTexts["Photos"].firstMatch.waitForExistence(timeout: 20))
        capture(app, "module4-photo-before-import")
        // The simulator was seeded with the public “Reading on iPad” PNG;
        // screenshot review confirms it is the leading thumbnail in this grid.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.35)).tap()
        XCTAssertTrue(app.buttons["readPlayPauseButton"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.scrollViews["photoReaderCanvas"].waitForExistence(timeout: 15))
        capture(app, "module4-imported-photo-landscape")
        rotate(app, .portrait)
        XCTAssertTrue(app.buttons["readPlayPauseButton"].isHittable)
        capture(app, "module4-imported-photo-portrait")
        app.buttons["readerMinimizeButton"].tap()
        app.terminate()
    }

    func testAccountProAndCloudFormsRotate() {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderIPadFormFixture", "-CastReaderRegion", "global",
            "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.buttons["ipadForm.login"].waitForExistence(timeout: 20))
        app.buttons["ipadForm.login"].tap()
        XCTAssertTrue(app.buttons["login.email"].waitForExistence(timeout: 10))
        app.buttons["login.email"].tap()
        let email = app.textFields["login.emailAddress"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap(); email.typeText("ipad-layout@example.com")
        rotate(app, .landscapeLeft)
        XCTAssertEqual(email.value as? String, "ipad-layout@example.com")
        XCTAssertTrue(app.buttons["ipadFormDone"].isHittable)
        let sendCode = app.buttons["login.sendCode"]
        for _ in 0..<5 where !sendCode.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(sendCode.isHittable)
        // Verify reachability without sending mail or changing the real account.
        capture(app, "module4-login-keyboard-landscape")
        rotate(app, .portrait)
        capture(app, "module4-login-keyboard-portrait")
        app.buttons["ipadFormDone"].tap()
        app.buttons["ipadForm.pro"].tap()
        XCTAssertTrue(app.buttons["ipadFormDone"].waitForExistence(timeout: 10))
        capture(app, "module4-pro-portrait")
        rotate(app, .landscapeLeft)
        app.swipeUp()
        capture(app, "module4-pro-landscape-actions")
        app.buttons["ipadFormDone"].tap()
        for provider in ["google_drive", "dropbox", "onedrive"] {
            app.buttons["ipadForm.\(provider)"].tap()
            let disclosure = app.descendants(matching: .any)["cloudPrivacy.\(provider)"].firstMatch
            XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
            capture(app, "module4-cloud-\(provider)-landscape")
            rotate(app, .portrait)
            capture(app, "module4-cloud-\(provider)-portrait")
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists && cancel.isHittable { cancel.tap() }
            else {
                let done = app.buttons["Done"].firstMatch
                for _ in 0..<5 where !done.isHittable { app.swipeUp() }
                XCTAssertTrue(done.isHittable)
                done.tap()
            }
            rotate(app, .landscapeLeft)
        }
        app.terminate()
    }

    func testSystemShareExtensionInBothOrientations() {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderIPadFormFixture", "-CastReaderRegion", "global",
            "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.buttons["ipadForm.share"].waitForExistence(timeout: 20))
        app.buttons["ipadForm.share"].tap()
        let reader = app.cells.matching(NSPredicate(format: "label == %@", "CastReader")).firstMatch
        if !reader.waitForExistence(timeout: 5) {
            let more = app.cells.matching(NSPredicate(format: "label == %@", "More")).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
        }
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        reader.tap()
        let save = app.buttons["castreaderShareSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        capture(app, "module4-share-extension-portrait")
        rotate(app, .landscapeLeft)
        XCTAssertTrue(save.isHittable)
        XCTAssertLessThanOrEqual(save.frame.width, 520)
        capture(app, "module4-share-extension-landscape")
        save.tap()
        XCTAssertTrue(app.buttons["ipadForm.share"].waitForExistence(timeout: 15))
        app.terminate()
    }

    func testLegacyIPadSidebarDestinations() {
        let app = home(extra: ["-CastReaderLegacyIPadNavigation"])
        rotate(app, .landscapeLeft)
        for title in ["Library", "Voice", "Settings", "Home"] {
            let item = app.buttons[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10))
            XCTAssertTrue(item.isHittable)
            item.tap()
            capture(app, "module4-legacy-sidebar-\(title)")
        }
        rotate(app, .portrait)
        XCTAssertTrue(app.buttons["plusImportButton"].isHittable)
        capture(app, "module4-legacy-sidebar-portrait")
        app.terminate()
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
