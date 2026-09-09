import XCTest

final class ReadingResumeScenarioUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true; XCUIDevice.shared.orientation = .portrait }

    func testLongEPUBColdResume() { run("epub") }
    func testEPUBSingleVeryLongParagraphColdResume() { run("epub-long") }
    func testLongTextColdResume() { run("text") }
    func testTextSingleVeryLongParagraphColdResume() { run("text-long") }
    func testLongMarkdownColdResume() { run("markdown") }
    func testLongDOCXColdResume() { run("docx") }
    func testDOCXSingleVeryLongParagraphColdResume() { run("docx-long") }
    func testLongWebArticleColdResume() { run("web") }
    func testWebSingleVeryLongParagraphColdResume() { run("web-long") }
    func testHundredTwentyPagePDFColdResume() { run("pdf") }
    func testHundredTwentyPageMixedPDFOCRColdResume() { run("pdf-ocr") }
    func testTallPhotoOCRColdResume() { run("photo") }
    func testLongYouTubeTranscriptColdResume() { run("youtube") }
    func testYouTubeVeryLongCaptionColdResume() { run("youtube-long") }
    func testEPUBBackgroundRotationMiniPlayerAndReopen() { run("epub-long", lifecycle: true) }
    func testWebBackgroundRotationMiniPlayerAndReopen() { run("web-long", lifecycle: true) }
    func testDOCXBackgroundRotationMiniPlayerAndReopen() { run("docx-long", lifecycle: true) }
    func testPDFBackgroundRotationMiniPlayerAndReopen() { run("pdf", lifecycle: true) }
    func testPhotoBackgroundRotationMiniPlayerAndReopen() { run("photo", lifecycle: true) }
    func testYouTubeBackgroundRotationMiniPlayerAndReopen() { run("youtube-long", lifecycle: true) }
    func testEPUBTerminationWhilePlayingKeepsRecentPosition() { run("epub-long", terminateWhilePlaying: true) }
    func testWebTerminationWhilePlayingKeepsRecentPosition() { run("web-long", terminateWhilePlaying: true) }
    func testEPUBReadExplainReadKeepsStoppedWord() { run("epub-long", switchModes: true) }
    func testWebReadExplainReadKeepsStoppedWord() { run("web-long", switchModes: true) }
    func testEPUBRealCloudSpeechColdResume() throws {
        guard ProcessInfo.processInfo.environment["CASTREADER_LIVE_RESUME"] == "1" else {
            throw XCTSkip("Opt-in live cloud TTS acceptance: CASTREADER_LIVE_RESUME=1")
        }
        run("epub", liveSpeech: true)
    }

    func testWebSearchKeyboardDoesNotShrinkReaderOrStrandPlaybackBar() {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderResumeScenario", "web-layout", "-CastReaderResetResumeScenario",
            "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-CastReaderForceDebugPro",
            "-auto_play", "NO", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let input = app.webViews.textFields["Search this book"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        let play = app.buttons["readPlayPauseButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let originalY = play.frame.midY
        input.tap()
        input.typeText("chapter")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.keyboards.firstMatch.frame.height, 150,
            "This regression requires an actual on-screen keyboard")
        XCTAssertEqual(play.frame.midY, originalY, accuracy: 4,
            "Search must not change the live reader viewport")
        app.webViews.buttons["Close search"].tap()
        XCTAssertTrue(waitForFrame(play, y: originalY))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(waitForFrame(play, y: originalY))
        attach(app, "web-keyboard-dismissed-height")
        app.terminate()
    }

    private func waitForFrame(_ element: XCUIElement, y: CGFloat) -> Bool {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && abs(element.frame.midY - y) < 4
        }, object: element)
        return XCTWaiter.wait(for: [expected], timeout: 8) == .completed
    }

    private func run(_ kind: String, lifecycle: Bool = false, liveSpeech: Bool = false, terminateWhilePlaying: Bool = false, switchModes: Bool = false) {
        let app = XCUIApplication()
        var args = ["-CastReaderResumeScenario", kind, "-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                    "-CastReaderForceDebugPro", "-auto_play", "NO", "-tts_speed", "1",
                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en"]
        if liveSpeech { args.append("-CastReaderResumeLiveSpeech") }
        app.launchArguments = args + ["-CastReaderResetResumeScenario"]
        app.launch()
        let status = app.staticTexts["scenarioStatus"]
        guard wait(status, timeout: 35, { self.number("target", $0) >= 0 }) else {
            XCTFail("\(kind): real parser/OCR/DOM extraction did not find the target: \(status.exists ? status.label : app.debugDescription)")
            attach(app, "\(kind)-not-ready"); app.terminate(); return
        }
        let target = number("target", status.label)
        app.buttons["scenarioSeekTarget"].tap()
        XCTAssertTrue(wait(status, timeout: liveSpeech ? 90 : 15) { $0.contains("playing=true") && self.number("time", $0) >= (terminateWhilePlaying ? 5 : liveSpeech ? 3 : 1) && self.number("paragraph", $0) == target }, status.label)
        if !terminateWhilePlaying {
            app.buttons["readPlayPauseButton"].tap()
            XCTAssertTrue(wait(status, timeout: 12) { $0.contains("playing=false") })
        }
        let before = status.label
        let segment = number("segment", before)
        var stopped = number("time", before)
        XCTAssertEqual(number("paragraph", before), target)
        attach(app, "\(kind)-\(terminateWhilePlaying ? "before-termination" : "paused")")
        if switchModes {
            let picker = app.segmentedControls["readerModePicker"]
            picker.buttons.element(boundBy: 1).tap()
            picker.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(wait(status, timeout: 10) { $0.contains("visible=true") && $0.contains("playing=false") },
                "Read → Explain → Read must reveal the stopped word before resuming: \(status.label)")
            attach(app, "\(kind)-mode-roundtrip")
            app.buttons["readPlayPauseButton"].tap()
            XCTAssertTrue(wait(status, timeout: 15) { $0.contains("playing=true") && self.number("first", $0) >= 0 })
            XCTAssertEqual(number("first", status.label), stopped, accuracy: 0.75)
            app.buttons["readPlayPauseButton"].tap()
            XCTAssertTrue(wait(status, timeout: 12) { $0.contains("playing=false") })
            stopped = number("time", status.label)
        }
        if lifecycle {
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(wait(status, timeout: 8) { $0.contains("playing=false") && self.number("paragraph", $0) == target })
            XCTAssertEqual(number("time", status.label), stopped, accuracy: 0.4)
            XCUIDevice.shared.orientation = .landscapeLeft
            // The production coordinator intentionally keeps transcripts in
            // portrait. Rotating the device must retain that layout and point.
            let remainsPortrait = kind.hasPrefix("youtube")
            XCTAssertTrue(wait(status, timeout: 12) {
                guard $0.contains("layoutStable=true") else { return false }
                let isLandscape = self.number("viewportWidth", $0) > self.number("viewportHeight", $0)
                return remainsPortrait ? !isLandscape : isLandscape
            }, "Wait for the reader's supported orientation to settle")
            XCTAssertTrue(wait(status, timeout: 10) { $0.contains("activeVisible=true") || $0.contains("visible=true") }, "Landscape lost the stopped position: \(status.label)")
            attach(app, "\(kind)-\(remainsPortrait ? "portrait-rotation-lock" : "landscape")")
            XCUIDevice.shared.orientation = .portrait
            XCTAssertTrue(wait(status, timeout: 12) { $0.contains("layoutStable=true") && self.number("viewportWidth", $0) < self.number("viewportHeight", $0) }, "Wait for portrait layout to settle")
            app.buttons["readerMinimizeButton"].tap()
            app.buttons["scenarioExpand"].tap()
            XCTAssertTrue(wait(status, timeout: 8) { $0.contains("activeVisible=true") || $0.contains("visible=true") }, "Mini Player expansion lost the stopped position")
            XCTAssertEqual(number("time", status.label), stopped, accuracy: 0.4)
            app.buttons["scenarioReopen"].tap()
            XCTAssertTrue(wait(status, timeout: 35) { self.number("paragraph", $0) == target && $0.contains("playing=false") })
            XCTAssertTrue(wait(status, timeout: 8) { $0.contains("visible=true") }, "Same-process reopen lost the stopped word: \(status.label)")
            attach(app, "\(kind)-same-process-reopen")
        }
        app.terminate()
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(wait(status, timeout: 35) { self.number("paragraph", $0) == target && $0.contains("playing=false") })
        XCTAssertTrue(wait(status, timeout: 8) { $0.contains("activeVisible=true") }, "\(kind): the saved word must be in the actual clipped viewport before playback: \(status.label)")
        if kind == "pdf" { XCTAssertTrue(status.label.contains("surface=pdf"), "Must test PDFKit, not extracted text") }
        if kind == "pdf-ocr" { XCTAssertTrue(status.label.contains("surface=text"), "A scanned page must use real OCR and the PDF reflow reader") }
        if kind == "photo" { XCTAssertTrue(status.label.contains("surface=photo"), "Must test the OCR image surface") }
        attach(app, "\(kind)-reopened")
        app.buttons["readPlayPauseButton"].tap()
        let tolerance = terminateWhilePlaying ? 3.0 : 0.75
        XCTAssertTrue(wait(status, timeout: liveSpeech ? 90 : 15) { $0.contains("playing=true") && self.number("time", $0) >= stopped - tolerance })
        XCTAssertEqual(number("segment", status.label), segment, "\(kind): wrong audio segment")
        XCTAssertEqual(number("paragraph", status.label), target)
        XCTAssertTrue(wait(status, timeout: 5) { self.number("first", $0) >= 0 })
        XCTAssertEqual(number("first", status.label), stopped, accuracy: tolerance,
            "The first observed AVPlayer playback sample must resume at the saved time")
        print("RESUME_ACCEPTANCE kind=\(kind) lifecycle=\(lifecycle) live=\(liveSpeech) terminatedPlaying=\(terminateWhilePlaying) stopped=\(stopped) first=\(number("first", status.label)) tolerance=\(tolerance)")
        XCTAssertTrue(wait(status, timeout: 8) { $0.contains("activeVisible=true") }, "\(kind): resumed audio must have the corresponding text visible: \(status.label)")
        attach(app, "\(kind)-resumed")
        app.buttons["readPlayPauseButton"].tap()
        app.terminate()
    }

    private func number(_ field: String, _ value: String) -> Double {
        value.split(separator: ";").first { $0.hasPrefix(field + "=") }
            .flatMap { Double($0.dropFirst(field.count + 1)) } ?? -1
    }
    private func wait(_ element: XCUIElement, timeout: Double, _ condition: @escaping (String) -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let view = object as? XCUIElement, view.exists else { return false }
            return condition(view.label)
        }, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        // App-element snapshots may crop a landscape window to cached portrait
        // bounds. Capture the physical screen for trustworthy rotation evidence.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
