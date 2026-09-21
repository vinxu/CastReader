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
        let ready = app.buttons["plusImportButton"].waitForExistence(timeout: 30)
        if !ready { capture(app, "home-readiness-failure") }
        XCTAssertTrue(ready)
        if app.windows.firstMatch.frame.width < 700 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
            let full = NSPredicate { _, _ in app.windows.firstMatch.frame.width >= 700 }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: full, object: app)], timeout: 10), .completed)
        }
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
        let scroll = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "importOptions.")).firstMatch
        for _ in 0..<16 where !source.isHittable { scroll.swipeUp() }
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

extension iPadAdaptationUITests {
    func testTwoActualWindowsKeepIndependentReadersAndTransferAudio() {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderMultiWindowFixture", "-CastReaderSkipSignInGate",
            "-CastReaderSkipLibraryOnboarding", "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        func button(_ id: String) -> XCUIElement { app.buttons[id].firstMatch }
        func status(_ n: Int, contains text: String, timeout: TimeInterval = 20) {
            let element = app.staticTexts["window\(n).status"].firstMatch
            let predicate = NSPredicate { _, _ in element.exists && element.label.contains(text) }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: timeout), .completed, "Expected \(text); \(element.exists ? element.label : app.debugDescription)")
        }
        func time(_ n: Int) -> Double {
            let text = app.staticTexts["window\(n).status"].firstMatch.label
            return Double(text.components(separatedBy: ";")[0].replacingOccurrences(of: "time=", with: "")) ?? -1
        }
        XCTAssertTrue(button("window1.play").waitForExistence(timeout: 30))
        button("window1.play").tap()
        status(1, contains: "w1:owner=true,playing=true")
        let advances = NSPredicate { _, _ in time(1) >= 3 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advances, object: app)], timeout: 10), .completed)
        let oldPosition = time(1)
        capture(app, "module5-window1-playing")
        button("window1.new").tap()
        XCTAssertTrue(button("window2.play").waitForExistence(timeout: 20))
        status(2, contains: "w1:owner=true,playing=true")
        status(2, contains: "w2:owner=false,playing=false")
        XCTAssertGreaterThan(time(2), oldPosition)
        capture(app, "module5-window2-browsing-window1-playing")
        button("window2.play").tap()
        status(2, contains: "w2:owner=true,playing=true")
        status(2, contains: "w1:owner=false,playing=false")
        capture(app, "module5-window2-takes-playback")
        button("window2.focus1").tap()
        XCTAssertTrue(button("window1.play").waitForExistence(timeout: 20))
        button("window1.play").tap()
        status(1, contains: "w1:owner=true,playing=true")
        XCTAssertGreaterThanOrEqual(time(1), oldPosition - 0.5)
        capture(app, "module5-window1-resumes-exact-position")
        button("window1.focus2").tap()
        XCTAssertTrue(button("window2.close").waitForExistence(timeout: 20))
        button("window2.close").tap()
        let firstFront = NSPredicate { _, _ in app.state == .runningForeground && button("window1.play").isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: firstFront, object: app)], timeout: 15), .completed)
        status(1, contains: "w1:owner=true,playing=true")
        capture(app, "module5-close-inactive-window-keeps-playing")
        button("window1.new").tap()
        XCTAssertTrue(button("window3.play").waitForExistence(timeout: 20))
        button("window3.focus1").tap()
        XCTAssertTrue(button("window1.close").waitForExistence(timeout: 20))
        button("window1.close").tap()
        status(3, contains: "w3:owner=true,playing=true")
        let front = NSPredicate { _, _ in app.state == .runningForeground && button("window3.pause").isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: front, object: app)], timeout: 15), .completed)
        capture(app, "module5-close-owner-moves-live-reader")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeWindow = NSPredicate { _, _ in
            let label = app.staticTexts["window3.status"].firstMatch.label
            return label.contains("orientation=3") || label.contains("orientation=4")
        }
        let rotationResult = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscapeWindow, object: app)], timeout: 10)
        capture(app, "module5-migration-rotation-probe")
        XCTAssertEqual(rotationResult, .completed, app.staticTexts["window3.status"].firstMatch.label)
        status(3, contains: "w3:owner=true,playing=true")
        capture(app, "module5-migrated-reader-landscape")
        button("window3.pause").tap()
        status(3, contains: "w3:owner=true,playing=false")
        app.terminate()
    }
}

extension iPadAdaptationUITests {
    func testWindowRestoresNativeDocumentAndModeWithoutAutoplay() {
        let app = home()
        importSource("text", app: app)
        let title = app.textFields["importTextTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap(); title.typeText("iPad window restore acceptance")
        let body = app.textViews["importTextBody"]
        body.tap(); body.typeText("A restored iPad window keeps this public sample ready to read. It must remain paused until the user explicitly asks for playback.")
        app.buttons["Start"].firstMatch.tap()
        XCTAssertTrue(app.buttons["readPlayPauseButton"].waitForExistence(timeout: 15))
        let explain = app.segmentedControls["readerModePicker"].buttons["Explain"]
        explain.tap()
        XCTAssertTrue(explain.isSelected)
        capture(app, "module5-window-before-process-restart")
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments += ["-CastReaderRestoreWindowAcceptance"]
        app.launch()
        let restored = app.buttons["readerMinimizeButton"].waitForExistence(timeout: 20)
        capture(app, "module5-restore-probe")
        XCTAssertTrue(restored)
        XCTAssertTrue(app.staticTexts["iPad window restore acceptance"].firstMatch.exists)
        XCTAssertTrue(app.segmentedControls["readerModePicker"].buttons["Explain"].isSelected)
        XCTAssertFalse(app.buttons["Pause"].firstMatch.exists)
        capture(app, "module5-window-restored-paused")
        rotate(app, .landscapeLeft)
        capture(app, "module5-window-restored-landscape")
        app.terminate()
    }
}

extension iPadAdaptationUITests {
    func testProductionNewWindowOpensIndependentHome() {
        let app = home()
        selectTab("Settings", app: app)
        let create = app.buttons["newReaderWindow"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        if !create.isHittable { app.swipeUp() }
        XCTAssertTrue(create.isHittable)
        capture(app, "module5-new-window-settings-entry")
        create.tap()
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["plusImportButton"].isHittable)
        capture(app, "module5-new-window-home")
        rotate(app, .landscapeLeft)
        XCTAssertTrue(app.buttons["plusImportButton"].isHittable)
        capture(app, "module5-new-window-home-landscape")
        app.terminate()
    }
}

extension iPadAdaptationUITests {
    func testKeyboardNavigationImportAndEditing() {
        let app = home()
        app.windows.firstMatch.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.buttons["libraryImportButton"].waitForExistence(timeout: 5))
        app.windows.firstMatch.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["newReaderWindow"].waitForExistence(timeout: 5))
        app.windows.firstMatch.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.buttons["importSource.text"].waitForExistence(timeout: 8))
        app.buttons["importSource.text"].tap()
        let text = app.textViews["importTextBody"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap(); text.typeText("Keyboard input")
        app.windows.firstMatch.typeKey(" ", modifierFlags: [])
        text.typeText("keeps spaces.")
        XCTAssertEqual(text.value as? String, "Keyboard input keeps spaces.")
        capture(app, "module6-keyboard-editor")
        app.terminate()
    }

    func testActualTextDropOpensReaderAfterRotation() {
        let app = home(extra: ["-CastReaderDropAcceptance"])
        let source = app.staticTexts["dropAcceptanceSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(app.buttons["dropImportRead"].waitForExistence(timeout: 15))
        capture(app, "module6-drop-review-portrait")
        rotate(app, .landscapeLeft)
        XCTAssertTrue(app.buttons["dropImportRead"].isHittable)
        capture(app, "module6-drop-review-landscape")
        app.buttons["dropImportRead"].tap()
        XCTAssertTrue(app.buttons["readerMinimizeButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textViews.firstMatch.value as? String == "iPad drag import keeps this public sample in the receiving window.")
        capture(app, "module6-dropped-text-reader")
        app.windows.firstMatch.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testSystemWindowResize() {
        let app = home()
        let original = app.windows.firstMatch.frame
        let bottomRight = app.coordinate(withNormalizedOffset: CGVector(dx: 0.992, dy: 0.992))
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.65))
        bottomRight.press(forDuration: 1.0, thenDragTo: destination)
        let resized = NSPredicate { _, _ in app.windows.firstMatch.frame.width < original.width - 100 }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: resized, object: app)], timeout: 10)
        capture(app, "module6-system-resize-probe")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "module6-system-resize-accessibility"; tree.lifetime = .keepAlways; add(tree)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(app.buttons["plusImportButton"].isHittable)
        app.terminate()
    }
}

extension iPadAdaptationUITests {
    func testNarrowWindowReaderAndPopover() {
        let app = home()
        importSource("text", app: app)
        XCTAssertTrue(app.textFields["importTextTitle"].waitForExistence(timeout: 10))
        app.textFields["importTextTitle"].tap(); app.textFields["importTextTitle"].typeText("A narrow iPad window")
        app.textViews["importTextBody"].tap()
        app.textViews["importTextBody"].typeText(String(repeating: "Reading controls stay reachable in a small window. ", count: 15))
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["readerMinimizeButton"].waitForExistence(timeout: 15))
        let origin = app.windows.firstMatch.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.992, dy: 0.992)).press(forDuration: 1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.65)))
        let resized = NSPredicate { _, _ in app.windows.firstMatch.frame.width < origin.width - 100 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: resized, object: app)], timeout: 10), .completed)
        for id in ["readerMinimizeButton", "readerModeMenu", "readPlayPauseButton", "readerMoreButton"] {
            let button = app.buttons[id].firstMatch
            XCTAssertTrue(button.isHittable, id)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, id)
        }
        capture(app, "module6-narrow-reader-375")
        app.buttons["readerMoreButton"].tap()
        XCTAssertTrue(app.buttons["readerAppearanceMenuItem"].waitForExistence(timeout: 5))
        capture(app, "module6-narrow-more")
        app.buttons["readerAppearanceMenuItem"].tap()
        XCTAssertTrue(app.buttons["readerSettingsDone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["readerSettingsDone"].isHittable)
        capture(app, "module6-narrow-appearance")
        app.buttons["readerSettingsDone"].tap()
        app.buttons["readerMinimizeButton"].tap()
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 5))
        capture(app, "module6-narrow-minimized")
        app.terminate()
    }

    func testLargestAccessibilityTextAndDarkAppearance() {
        let app = home(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-CastReaderIPadDarkAppearance"])
        capture(app, "module6-largest-type-home")
        importSource("text", app: app)
        let body = app.textViews["importTextBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 8)); body.tap(); body.typeText("Large text remains readable on iPad.")
        XCTAssertTrue(app.buttons["Start"].isHittable)
        app.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["readerMinimizeButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["readPlayPauseButton"].isHittable)
        for name in ["gobackward.15", "goforward.15"] {
            let button = app.buttons[name]
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        capture(app, "module6-largest-type-reader-portrait")
        rotate(app, .landscapeLeft)
        XCTAssertTrue(app.buttons["readerMoreButton"].isHittable)
        capture(app, "module6-largest-type-reader-landscape")
        app.buttons["readerMoreButton"].tap()
        capture(app, "module6-largest-type-more")
        app.terminate()
    }

    func testKeyboardPlaybackAndThirtyGeometryChanges() {
        let app = scenario("text-long")
        let status = app.staticTexts["scenarioStatus"]
        XCTAssertTrue(waitForStatus(status, timeout: 45) { self.number("target", in: $0) >= 0 })
        app.buttons["scenarioSeekTarget"].tap()
        XCTAssertTrue(waitForStatus(status) { $0.contains("playing=true") })
        app.windows.firstMatch.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForStatus(status) { $0.contains("playing=false") })
        app.windows.firstMatch.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForStatus(status) { $0.contains("playing=true") })
        for index in 0..<30 {
            let orientation: UIDeviceOrientation = index.isMultiple(of: 2) ? .landscapeLeft : .portrait
            rotate(app, orientation)
            XCTAssertTrue(waitForStatus(status) { $0.contains("layoutStable=true") && $0.contains("playing=true") })
            if index.isMultiple(of: 10) { capture(app, "module6-rotation-stress-\(index)") }
        }
        app.windows.firstMatch.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitForStatus(status) { $0.contains("playing=false") })
        let checkpoint = number("time", in: status.label)
        rotate(app, .landscapeLeft)
        XCTAssertEqual(number("time", in: status.label), checkpoint, accuracy: 0.4)
        capture(app, "module6-rotation-stress-final-paused")
        app.terminate()
    }
}

extension iPadAdaptationUITests {
    func testActualPDFDropAndKeyboardNewWindow() { verifyPDFDropAndNewWindow(usingKeyboard: true) }
    func testActualPDFDropAndWindowControls() { verifyPDFDropAndNewWindow(usingKeyboard: false) }

    private func verifyPDFDropAndNewWindow(usingKeyboard: Bool) {
        let app = home(extra: ["-CastReaderDropAcceptance", "-CastReaderDropPDF"])
        let source = app.staticTexts["dropAcceptanceSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        XCTAssertTrue(app.buttons["dropImportRead"].waitForExistence(timeout: 15))
        app.buttons["dropImportRead"].tap()
        XCTAssertTrue(app.buttons["readerMinimizeButton"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["pdfReaderCanvas"].firstMatch.exists)
        rotate(app, .landscapeLeft)
        let pdf = app.descendants(matching: .any)["pdfReaderCanvas"].firstMatch
        XCTAssertTrue((pdf.value as? String ?? "").contains("firstVisible=true"))
        capture(app, "module6-dropped-pdf-landscape")
        if usingKeyboard { app.windows.firstMatch.typeKey(.escape, modifierFlags: []) }
        else { app.buttons["readerMinimizeButton"].tap() }
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 5))
        let minimized = NSPredicate { _, _ in !app.buttons["readerMinimizeButton"].isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: minimized, object: app)], timeout: 8), .completed)
        if usingKeyboard { app.windows.firstMatch.typeKey("4", modifierFlags: .command) }
        else { selectTab("Settings", app: app) }
        XCTAssertTrue(app.buttons["newReaderWindow"].waitForExistence(timeout: 5))
        if usingKeyboard { app.windows.firstMatch.typeKey("n", modifierFlags: .command) }
        else {
            let newWindow = app.buttons["newReaderWindow"]
            // Bring the whole row above the floating mini player before tapping.
            for _ in 0..<3 where newWindow.frame.maxY > app.windows.firstMatch.frame.maxY - 150 {
                app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeUp()
            }
            newWindow.tap()
        }
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["plusImportButton"].isHittable)
        capture(app, usingKeyboard ? "module6-keyboard-new-window" : "module6-pdf-drop-new-window")
        app.terminate()
    }
}

extension iPadAdaptationUITests {
    func testDropQueueReviewsIndividualResultsInBothOrientations() {
        let app = home(extra: ["-CastReaderDropAcceptance", "-CastReaderDropQueueAcceptance"])
        let source = app.staticTexts["dropAcceptanceSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
        let importAll = app.buttons["dropImportAll"]
        XCTAssertTrue(importAll.waitForExistence(timeout: 15)); importAll.tap()
        let completed = NSPredicate { _, _ in app.buttons.matching(identifier: "dropQueuedRead").count == 2 && importAll.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: completed, object: app)], timeout: 30), .completed)
        capture(app, "module6-drop-queue-portrait")
        rotate(app, .landscapeLeft)
        capture(app, "module6-drop-queue-landscape")
        let read = app.buttons.matching(identifier: "dropQueuedRead").firstMatch
        if !read.isHittable { app.scrollViews.firstMatch.swipeDown() }
        read.tap()
        XCTAssertTrue(app.buttons["readerMinimizeButton"].waitForExistence(timeout: 10))
        capture(app, "module6-drop-queue-open-paused")
        app.terminate()
    }
}

extension iPadAdaptationUITests {
    func testSystemTextEditorCommandModifierContract() {
        let app = home()
        importSource("text", app: app)
        let text = app.textViews["importTextBody"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap(); text.typeText("Public original")
        text.typeKey("a", modifierFlags: .command)
        capture(app, "module6-system-editor-selection")
        text.typeText("Replaced")
        capture(app, "module6-system-editor-command-modifier")
        XCTAssertEqual(text.value as? String, "Replaced", "System UITextView must receive Command-A before testing app shortcuts")
        app.terminate()
    }
}
